defmodule Sake.Skill do
  @moduledoc """
  A skill: a `SKILL.md` and the files beside it, served over the Skills
  extension (`io.modelcontextprotocol/skills`, SEP-2640) so that a client
  can find the workflow a server ships with its tools and load it when it
  needs it.

  A skill packaged with its server is a directory, compiled into a module:

      priv/skills/run-report/       (or anywhere in the project)
        SKILL.md
        references/FILTERS.md
        templates/weekly.md

      defmodule Reports.MCP.RunReport do
        use Sake.Skill, dir: "../../priv/skills/run-report"
      end

      defmodule Reports.MCP do
        use Sake.Server, name: "reports", version: "1.4.0"
        tools [Reports.MCP.ListReports, Reports.MCP.RunReport]
        skills [Reports.MCP.RunReport]
      end

  `dir:` is relative to the module's own file. Every file under it,
  except hidden ones (a name that starts with a `.`), is part of the
  skill. They are read when the module compiles, which checks the skill
  (below) and computes its manifest: each file's size and SHA-256 digest.
  The module recompiles when a file changes, or is added or removed.

  Options: `dir:` (required), `path:` (the skill's path, the part of its
  URI between `skill://` and `/SKILL.md`; default its `name`; its last
  segment must be the `name`), `scope:` (one or many) and
  `authentication:` (as a resource's: they gate `skills/get` and every
  read of the skill's files, and a skill the token's scopes do not cover
  is not listed), `ttl:` (ms, the longest a client may keep its entry),
  and `meta:` (the entry's `_meta`).

  Skills the host learns at runtime (from its database, say) come from a
  `Sake.Skill.Catalog`, which builds them with `build/2` or `dynamic/2`.

  ## What is checked

  `SKILL.md` must begin with YAML frontmatter that has a `name` and a
  `description` (see `Sake.Skill.Frontmatter` for the YAML it reads). The
  name is 1 to 64 lowercase letters, digits and hyphens, neither starting
  nor ending with a hyphen nor holding two in a row (the Agent Skills
  rules). Keys of the frontmatter's `metadata` under
  `io.modelcontextprotocol/` are the protocol's, and refused. A skill has
  at most 512 files and 16 MiB in all, the limits every client supports.

  ## On the wire

  The server declares the extension, with `directoryRead: true`, and
  answers `skills/list` and `skills/get` with each skill's entry: the URI
  of its `SKILL.md`, its frontmatter, and its manifest (`resources`).
  `resources/read` serves its files at `skill://<path>/<file>`, and
  `resources/directory/read` its directories. `resources/list` lists each
  `SKILL.md` too, with the skill's name and description, so a client
  without the extension still finds it as an ordinary resource.
  """

  alias Sake.Skill.Frontmatter

  @typedoc "One file of a skill's manifest."
  @type resource :: %{uri: String.t(), digest: String.t(), size: non_neg_integer()}

  @typedoc """
  A skill. `uri` is its `SKILL.md`'s, `resources` its manifest (or
  `:dynamic`), `files` the content of the files it holds, by URI, and
  `paths` each file's path within the skill, by URI.
  """
  @type t :: %__MODULE__{
          uri: String.t(),
          path: String.t(),
          frontmatter: map(),
          resources: [resource()] | :dynamic,
          files: %{String.t() => binary()},
          paths: %{String.t() => String.t()},
          meta: map() | nil
        }

  defstruct [:uri, :path, :frontmatter, :resources, files: %{}, paths: %{}, meta: nil]

  @extension "io.modelcontextprotocol/skills"
  @max_files 512
  @max_size 16 * 1024 * 1024
  @name_re ~r/^(?!.*--)[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/
  @segment_re ~r/^[A-Za-z0-9\-._~!$&'()*+,;=]+$/
  @reserved "io.modelcontextprotocol/"

  @doc "The identifier of the Skills extension."
  @spec extension() :: String.t()
  def extension, do: @extension

  @doc "The most files a skill may have."
  @spec max_files() :: pos_integer()
  def max_files, do: @max_files

  @doc "The most bytes a skill's files may hold in all."
  @spec max_size() :: pos_integer()
  def max_size, do: @max_size

  @doc """
  A skill from its files, a map from each one's path within the skill
  (`"SKILL.md"`, `"references/FORMS.md"`) to its content, with its
  manifest computed. Options: `path:` (default: the skill's name) and
  `meta:` (the entry's `_meta`). A skill of a `Sake.Skill.Catalog`.
  """
  @spec build(%{String.t() => binary()}, keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(files, opts \\ []) when is_map(files) do
    with :ok <- check_files(files),
         {:ok, skill_md} <- fetch_skill_md(files),
         {:ok, frontmatter} <- frontmatter(skill_md),
         {:ok, path} <- skill_path(opts[:path], frontmatter["name"]),
         :ok <- check_limits(files) do
      ordered = Enum.sort_by(files, fn {file, _} -> {file != "SKILL.md", file} end)
      uris = Map.new(ordered, fn {file, _} -> {file, file_uri(path, file)} end)

      {:ok,
       %__MODULE__{
         uri: uris["SKILL.md"],
         path: path,
         frontmatter: frontmatter,
         resources:
           Enum.map(ordered, fn {file, content} ->
             %{uri: uris[file], digest: digest(content), size: byte_size(content)}
           end),
         files: Map.new(ordered, fn {file, content} -> {uris[file], content} end),
         paths: Map.new(uris, fn {file, uri} -> {uri, file} end),
         meta: opts[:meta]
       }}
    end
  end

  @doc """
  A skill whose content is generated when it is read, so that it has no
  manifest (`"resources": "dynamic"` on the wire). Its `SKILL.md` is
  `skill_md`; its other files are read with the catalog's `read/3`.
  Options: `path:`, `meta:`, and `files:` (the paths of its other files,
  for `resources/directory/read`, the only way a client can find them).

  A dynamic skill offers no integrity, and a client may refuse to load
  it: prefer `build/2` when the content is known.
  """
  @spec dynamic(binary(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def dynamic(skill_md, opts \\ []) when is_binary(skill_md) do
    others = opts[:files] || []

    with :ok <- check_files(Map.new(["SKILL.md" | others], &{&1, ""})),
         {:ok, frontmatter} <- frontmatter(skill_md),
         {:ok, path} <- skill_path(opts[:path], frontmatter["name"]) do
      uri = file_uri(path, "SKILL.md")
      paths = Map.new(["SKILL.md" | others], &{file_uri(path, &1), &1})

      {:ok,
       %__MODULE__{
         uri: uri,
         path: path,
         frontmatter: frontmatter,
         resources: :dynamic,
         files: %{uri => skill_md},
         paths: paths,
         meta: opts[:meta]
       }}
    end
  end

  @doc "The `sha256:<hex>` digest of `content`, as a manifest has it."
  @spec digest(binary()) :: String.t()
  def digest(content),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  @doc """
  Checks `content`, read from `uri`, against the skill's `entry` (a
  `skills/list` or `skills/get` entry, as the server sent it): the file
  must be in the entry's manifest, with that size and digest, and a
  `SKILL.md` must have the entry's frontmatter. A dynamic entry has no
  manifest to check against: `{:error, :dynamic}`.
  """
  @spec verify(map(), String.t(), binary()) ::
          :ok
          | {:error,
             :dynamic
             | :invalid_entry
             | :unlisted
             | :size_mismatch
             | :digest_mismatch
             | {:frontmatter_mismatch, [String.t()]}
             | {:frontmatter, String.t()}}
  def verify(%{"resources" => "dynamic"}, _uri, _content), do: {:error, :dynamic}

  def verify(%{"uri" => _skill_uri, "resources" => resources} = entry, uri, content)
      when is_list(resources) and is_binary(content) do
    case Enum.find(resources, &(is_map(&1) and &1["uri"] == uri)) do
      nil -> {:error, :unlisted}
      %{"size" => size, "digest" => digest} -> verify_bytes(entry, uri, size, digest, content)
      _ -> {:error, :invalid_entry}
    end
  end

  def verify(_entry, _uri, _content), do: {:error, :invalid_entry}

  # A size that differs fails as a digest that does, without hashing.
  defp verify_bytes(entry, uri, size, digest, content) do
    cond do
      size != byte_size(content) -> {:error, :size_mismatch}
      digest != digest(content) -> {:error, :digest_mismatch}
      uri == entry["uri"] -> verify_frontmatter(entry, content)
      true -> :ok
    end
  end

  defp verify_frontmatter(%{"frontmatter" => expected}, content) when is_map(expected) do
    case Frontmatter.split(content) do
      {:ok, actual, _body} ->
        keys = Enum.uniq(Map.keys(actual) ++ Map.keys(expected))

        case Enum.reject(keys, &same?(actual[&1], expected[&1])) |> Enum.sort() do
          [] -> :ok
          differing -> {:error, {:frontmatter_mismatch, differing}}
        end

      {:error, message} ->
        {:error, {:frontmatter, message}}
    end
  end

  defp verify_frontmatter(_entry, _content), do: {:error, :invalid_entry}

  # JSON has one kind of number: 1 and 1.0 are the same value.
  defp same?(a, b) when is_number(a) and is_number(b), do: a == b

  defp same?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> same?(x, y) end)

  defp same?(a, b) when is_map(a) and is_map(b),
    do:
      Map.keys(a) |> Enum.sort() == Map.keys(b) |> Enum.sort() and
        Enum.all?(a, fn {k, v} -> same?(v, b[k]) end)

  defp same?(a, b), do: a === b

  @doc "The entry of a skill on the wire, at its URIs as the client knows them."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = skill) do
    resources =
      case skill.resources do
        :dynamic ->
          "dynamic"

        list ->
          Enum.map(list, &%{"uri" => &1.uri, "digest" => &1.digest, "size" => &1.size})
      end

    %{"uri" => skill.uri, "frontmatter" => skill.frontmatter, "resources" => resources}
    |> then(&if(skill.meta, do: Map.put(&1, "_meta", skill.meta), else: &1))
  end

  @doc false
  # The URI of a file of the skill at `path`.
  def file_uri(path, file) do
    "skill://" <> path <> "/" <> (file |> String.split("/") |> Enum.map_join("/", &encode/1))
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  @doc false
  # The skill's root directory: its SKILL.md's URI without the file.
  def root(%__MODULE__{uri: uri}), do: root(uri)
  def root(uri) when is_binary(uri), do: String.replace_suffix(uri, "/SKILL.md", "")

  @doc false
  # The skill with every URI moved by `fun` (a mount's prefix, say).
  def map_uris(%__MODULE__{} = skill, fun) do
    resources =
      case skill.resources do
        :dynamic -> :dynamic
        list -> Enum.map(list, &%{&1 | uri: fun.(&1.uri)})
      end

    %{
      skill
      | uri: fun.(skill.uri),
        resources: resources,
        files: Map.new(skill.files, fn {uri, content} -> {fun.(uri), content} end),
        paths: Map.new(skill.paths, fn {uri, file} -> {fun.(uri), file} end)
    }
  end

  # ---- checks

  defp check_files(files) do
    Enum.find_value(files, :ok, fn
      {file, content} when is_binary(file) and is_binary(content) ->
        case file_error(file) do
          nil -> nil
          message -> {:error, message}
        end

      {file, _content} ->
        {:error, "the files of a skill are a map of paths to binaries, got #{inspect(file)}"}
    end)
  end

  defp file_error(file) do
    segments = String.split(file, "/")

    cond do
      file == "" or String.starts_with?(file, "/") ->
        "#{inspect(file)} is not a relative path"

      Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        "#{inspect(file)} is not a path within the skill"

      not String.valid?(file) ->
        "#{inspect(file)} is not UTF-8"

      true ->
        nil
    end
  end

  defp fetch_skill_md(files) do
    case Map.fetch(files, "SKILL.md") do
      {:ok, text} -> {:ok, text}
      :error -> {:error, "a skill needs a SKILL.md at its root"}
    end
  end

  @doc false
  # The checked frontmatter of a SKILL.md.
  def frontmatter(skill_md) do
    with {:ok, frontmatter, _body} <- Frontmatter.split(skill_md) do
      name = frontmatter["name"]
      description = frontmatter["description"]

      cond do
        not is_binary(name) ->
          {:error, "the frontmatter of SKILL.md needs a name"}

        not Regex.match?(@name_re, name) ->
          {:error,
           "the skill name #{inspect(name)} must be 1-64 lowercase letters, digits and hyphens, " <>
             "neither starting nor ending with a hyphen nor holding two in a row"}

        not is_binary(description) or String.trim(description) == "" ->
          {:error, "the frontmatter of SKILL.md needs a description"}

        reserved = reserved_key(frontmatter["metadata"]) ->
          {:error, "the metadata key #{inspect(reserved)} is reserved for the protocol"}

        true ->
          {:ok, frontmatter}
      end
    end
  end

  defp reserved_key(%{} = metadata),
    do: metadata |> Map.keys() |> Enum.find(&String.starts_with?(&1, @reserved))

  defp reserved_key(_metadata), do: nil

  defp skill_path(nil, name), do: {:ok, name}

  defp skill_path(path, name) when is_binary(path) do
    segments = String.split(path, "/")

    cond do
      not Enum.all?(segments, &Regex.match?(@segment_re, &1)) or
          Enum.any?(segments, &(&1 in [".", ".."])) ->
        {:error,
         "the skill path #{inspect(path)} must be segments of letters, digits and -._~!$&'()*+,;= " <>
           "separated by /"}

      List.last(segments) != name ->
        {:error,
         "the skill path #{inspect(path)} must end with the skill's name, #{inspect(name)}"}

      true ->
        {:ok, path}
    end
  end

  defp skill_path(path, _name),
    do: {:error, "the skill path must be a string, got #{inspect(path)}"}

  defp check_limits(files) do
    total = files |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

    cond do
      map_size(files) > @max_files ->
        {:error, "a skill has at most #{@max_files} files, this one has #{map_size(files)}"}

      total > @max_size ->
        {:error, "a skill holds at most #{@max_size} bytes, this one holds #{total}"}

      true ->
        :ok
    end
  end

  # ---- a skill packaged in a module

  @doc "The skill's compiled definition."
  @callback spec() :: Sake.Skill.Spec.t()

  defmacro __using__(opts) do
    quote do
      @behaviour Sake.Skill
      @sake_opts unquote(opts)
      @before_compile Sake.Skill
    end
  end

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :sake_opts)
    dir = opts[:dir] || raise ArgumentError, "#{inspect(env.module)}: a skill needs a dir:"
    root = Path.expand(dir, Path.dirname(env.file))

    if not File.dir?(root) do
      raise ArgumentError, "#{inspect(env.module)}: the skill directory #{root} does not exist"
    end

    paths = files_in(root)
    files = Map.new(paths, &{&1, File.read!(Path.join(root, &1))})

    skill =
      case build(files, path: opts[:path], meta: opts[:meta]) do
        {:ok, skill} -> skill
        {:error, message} -> raise ArgumentError, "#{inspect(env.module)}: #{message}"
      end

    spec = %Sake.Skill.Spec{
      module: env.module,
      uri: skill.uri,
      skill: skill,
      scopes: List.wrap(opts[:scope]),
      authentication:
        Sake.Auth.Authentication.requirement!(opts[:authentication], inspect(env.module)),
      ttl: opts[:ttl]
    }

    externals =
      for path <- paths, do: quote(do: @external_resource(unquote(Path.join(root, path))))

    quote do
      unquote_splicing(externals)

      @impl Sake.Skill
      def spec, do: unquote(Macro.escape(spec))

      # A file added to or removed from the directory recompiles the
      # module, as a change to one it has does (`@external_resource`).
      def __mix_recompile__?,
        do: Sake.Skill.files_in(unquote(root)) != unquote(paths)
    end
  end

  @doc false
  # The skill's files under `root`, by their paths within it, hidden ones
  # left out.
  def files_in(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end
end
