defmodule Sake.Server.Skills do
  @moduledoc false
  # The Skills extension (`Sake.Skill`) on the server: the skills a
  # request sees, finding one by URI, its files and directories, and the
  # methods (`skills/list`, `skills/get`, `resources/directory/read`, and
  # the reads of skill files `resources/read` hands over).
  #
  # A skill comes from one of three places: a `Sake.Skill` module (its
  # spec carries the skill, compiled in), a `Sake.Skill.Catalog` (its spec
  # has no skill until the catalog gives one, for the request), or a
  # proxy's upstream. Through a mount, every URI of a skill takes the
  # mount's prefix as a resource's does, and its digests stay what they
  # were: the files are the same bytes.

  require Logger

  alias Sake.{Context, JSONRPC, Server, Skill}
  alias Sake.Server.{Dispatch, Middleware, Mount}
  alias Sake.Skill.Spec

  @directory "inode/directory"

  # ---- the extension

  @doc "The server's extensions, with the skills extension when it serves skills."
  @spec extensions(map(), module()) :: map()
  def extensions(ext, server) do
    if Server.skills?(server),
      do: Map.put_new(ext, Skill.extension(), %{"directoryRead" => true}),
      else: ext
  end

  @doc "The legacy `initialize` capabilities, with the extension."
  @spec advertise(map(), module()) :: map()
  def advertise(caps, server) do
    case extensions(%{}, server) do
      ext when ext == %{} -> caps
      ext -> Map.update(caps, "extensions", ext, &Map.merge(&1, ext))
    end
  end

  # ---- the skills a request sees

  @doc "The skills of the server for the request; see `Sake.Server.skills/2`."
  @spec list(module(), Context.t()) :: [Spec.t()]
  def list(server, ctx) do
    {catalogs, static} = Enum.split_with(server.__sake__(:skills), & &1.catalog)
    from_catalogs = Enum.flat_map(catalogs, &catalog_skills(&1, ctx))
    own = unique(static ++ from_catalogs)
    own ++ Server.proxied_components(server, :skills, own, ctx)
  end

  defp catalog_skills(spec, ctx) do
    for skill <- catalog_list(spec, ctx), {:ok, s} <- [with_skill(spec, skill)], do: s
  end

  defp catalog_list(%{module: module} = spec, ctx) do
    case module.list(Mount.component_ctx(spec, ctx)) do
      list when is_list(list) ->
        Enum.filter(list, fn
          %Skill{} ->
            true

          other ->
            Logger.warning(
              "#{inspect(module)}.list/1 returned #{inspect(other)}, not a Sake.Skill"
            )

            false
        end)

      other ->
        Logger.warning("#{inspect(module)}.list/1 returned #{inspect(other)}, not a list")
        []
    end
  end

  defp unique(specs) do
    {kept, _seen} =
      Enum.reduce(specs, {[], MapSet.new()}, fn spec, {kept, seen} ->
        if MapSet.member?(seen, spec.uri) do
          Logger.debug("left out a second skill at #{spec.uri}")
          {kept, seen}
        else
          {[spec | kept], MapSet.put(seen, spec.uri)}
        end
      end)

    Enum.reverse(kept)
  end

  @doc """
  A catalog's spec with one of its skills, given at the catalog's own
  URIs: each mount between the catalog and the server moves it under its
  prefix.
  """
  @spec with_skill(Spec.t(), Skill.t()) :: {:ok, Spec.t()} | :error
  def with_skill(%Spec{mount: nil} = spec, skill),
    do: {:ok, %{spec | skill: skill, uri: skill.uri}}

  def with_skill(%Spec{mount: {server, prefix, inner}} = spec, skill) do
    with {:ok, inner} <- with_skill(inner, skill),
         {:ok, outer} <- Mount.skill_uris(inner.skill, prefix) do
      {:ok, %{spec | skill: outer, uri: outer.uri, mount: {server, prefix, inner}}}
    end
  end

  @doc """
  The skill whose `SKILL.md` is at `uri`: one of the server's own, one a
  catalog gives for it (listed or not), or one of a proxy's upstream (one
  it lists, else the one its `skills/get` answers with).
  """
  @spec find(module(), String.t(), Context.t(), boolean()) :: {:ok, Spec.t()} | :error
  def find(server, uri, ctx, ask_upstream? \\ true) do
    {catalogs, static} = Enum.split_with(server.__sake__(:skills), & &1.catalog)

    with :error <- find_static(static, uri),
         :error <- find_in_catalogs(catalogs, uri, ctx) do
      find_proxied(server, uri, ctx, static, ask_upstream?)
    end
  end

  defp find_static(static, uri) do
    case Enum.find(static, &(&1.uri == uri)) do
      nil -> :error
      spec -> {:ok, spec}
    end
  end

  defp find_in_catalogs(catalogs, uri, ctx) do
    Enum.find_value(catalogs, :error, fn spec ->
      with {:ok, inner} <- Mount.inner_uri(spec, uri),
           {:ok, path} <- skill_path(inner),
           {:ok, %Skill{uri: ^inner} = skill} <- fetch(spec, path, ctx),
           {:ok, found} <- with_skill(spec, skill) do
        {:ok, found}
      else
        _ -> nil
      end
    end)
  end

  # The path of a `skill://<path>/SKILL.md` URI.
  defp skill_path("skill://" <> rest) do
    case String.split(rest, "/") do
      [_ | _] = segments when length(segments) > 1 ->
        if List.last(segments) == "SKILL.md",
          do: {:ok, segments |> Enum.drop(-1) |> Enum.join("/")},
          else: :error

      _ ->
        :error
    end
  end

  defp skill_path(_uri), do: :error

  defp fetch(%{module: module} = spec, path, ctx) do
    ctx = Mount.component_ctx(spec, ctx)

    if function_exported?(module, :fetch, 2) do
      case module.fetch(path, ctx) do
        {:ok, %Skill{} = skill} -> {:ok, skill}
        _ -> :error
      end
    else
      case Enum.find(catalog_list(spec, ctx), &(&1.path == path)) do
        nil -> :error
        skill -> {:ok, skill}
      end
    end
  end

  defp find_proxied(server, uri, ctx, static, ask_upstream?) do
    listed = Server.proxied_components(server, :skills, static, ctx)

    case Enum.find(listed, &(&1.uri == uri)) do
      nil when ask_upstream? -> ask_upstream(server, uri, ctx)
      nil -> :error
      spec -> {:ok, spec}
    end
  end

  # A skill a proxy's upstream does not list may still be one it serves:
  # its `skills/get` says.
  defp ask_upstream(server, uri, ctx) do
    Enum.find_value(server.__sake__(:sources), :error, fn {proxy, chain} ->
      with true <- Sake.Proxy.exposes(proxy).skills,
           {:ok, inner} <- Server.unwrap_uri(chain, uri),
           {:ok, spec} <- Sake.Proxy.skill(proxy, inner, ctx),
           [spec] <- Server.wrap_chain(spec, chain) do
        {:ok, Server.with_server_authentication(server, spec)}
      else
        _ -> nil
      end
    end)
  end

  @doc """
  The skill a file at `uri` belongs to: the one whose manifest lists it,
  or, for a dynamic skill, whose directory it is in. A skill of a
  catalog's need not be listed; an upstream's must be (a file of one it
  does not list is read as any other proxied resource is).
  """
  @spec file(module(), String.t(), Context.t()) :: {:ok, Spec.t()} | :error
  def file(server, uri, ctx) do
    uri
    |> ancestors()
    |> Enum.find_value(:error, fn dir ->
      with {:ok, spec} <- find(server, dir <> "/SKILL.md", ctx, false),
           true <- holds?(spec.skill, uri) do
        {:ok, spec}
      else
        _ -> nil
      end
    end)
  end

  # The directories a URI is in, the closest first: `skill://a/b/c.md`
  # is in `skill://a/b` and `skill://a`.
  defp ancestors(uri) do
    case Regex.run(~r/^([A-Za-z][A-Za-z0-9+.\-]*:\/\/)(.+)$/, uri, capture: :all_but_first) do
      [scheme, rest] ->
        segments = String.split(rest, "/")

        for n <- (length(segments) - 1)..1//-1,
            do: scheme <> Enum.join(Enum.take(segments, n), "/")

      nil ->
        []
    end
  end

  defp holds?(%Skill{resources: :dynamic} = skill, uri),
    do: String.starts_with?(uri, Skill.root(skill) <> "/")

  defp holds?(%Skill{resources: resources}, uri), do: Enum.any?(resources, &(&1.uri == uri))

  # The URIs of the skill's files, as far as they are known.
  defp file_uris(%Skill{resources: :dynamic, paths: paths}), do: Map.keys(paths)
  defp file_uris(%Skill{resources: resources}), do: Enum.map(resources, & &1.uri)

  @doc """
  The resource spec a read of the skill's file at `uri` goes through, as
  the read middleware sees it: its scopes, authentication and ttl are the
  skill's.
  """
  @spec file_resource(module(), String.t(), Context.t()) :: {:ok, Sake.Resource.Spec.t()} | :error
  def file_resource(server, uri, ctx) do
    with {:ok, spec} <- file(server, uri, ctx) do
      {:ok,
       %Sake.Resource.Spec{
         uri: uri,
         name: file_name(spec, uri),
         mime_type: mime_type(uri),
         scopes: spec.scopes,
         authentication: spec.authentication,
         ttl: spec.ttl,
         proxy: spec.proxy,
         skill: spec
       }}
    end
  end

  defp file_name(%{skill: skill}, uri) do
    if uri == skill.uri,
      do: skill.frontmatter["name"],
      else: uri |> String.split("/") |> List.last()
  end

  defp mime_type(uri) do
    if String.ends_with?(uri, "/SKILL.md"),
      do: "text/markdown",
      else: MIME.from_path(uri |> URI.parse() |> Map.get(:path) || uri)
  end

  # ---- skills/list

  @spec list_skills(module(), map(), Context.t()) :: term()
  def list_skills(server, params, ctx) do
    with {:ok, offset} <- Dispatch.offset(params, ctx),
         {:ok, specs} <- listed(server, params, ctx) do
      {page, next} = Dispatch.page(specs, offset, server)

      {:ok,
       %{"skills" => Enum.map(page, &Skill.to_wire(&1.skill))}
       |> Dispatch.next_cursor(next, ctx)
       |> Dispatch.cacheable(server, ctx, Enum.map(page, & &1.ttl))
       |> Middleware.cache_scope(server, [:after_list])
       |> cache_scope(server)}
    end
  end

  @doc "The skills the request may see, as the lists show them."
  def listed(server, params, ctx) do
    server
    |> list(ctx)
    |> Enum.filter(&Server.allowed?(&1, ctx))
    |> Dispatch.listable(:skills, params, ctx)
  end

  @doc """
  The `resources/list` entries of the skills' `SKILL.md`s, each with its
  skill's ttl, for a client without the extension to find them.
  """
  @spec resource_entries(module(), map(), Context.t()) :: {:ok, [{term(), map()}]} | term()
  def resource_entries(server, params, ctx) do
    if server.__sake__(:skills) == [] and not Server.skills?(server) do
      {:ok, []}
    else
      with {:ok, specs} <- listed(server, params, ctx) do
        {:ok,
         for %{skill: skill} = spec <- specs do
           {spec.ttl,
            %{
              "uri" => skill.uri,
              "name" => skill.frontmatter["name"],
              "description" => skill.frontmatter["description"],
              "mimeType" => "text/markdown"
            }}
         end}
      end
    end
  end

  @doc """
  What a catalog or a proxy lists depends on who asks, so no shared cache
  may keep a result that holds skills.
  """
  def cache_scope(%{"cacheScope" => _} = result, server) do
    if private?(server), do: Map.put(result, "cacheScope", "private"), else: result
  end

  def cache_scope(result, _server), do: result

  defp private?(server),
    do: Server.dynamic?(server) or Enum.any?(server.__sake__(:skills), & &1.catalog)

  # ---- skills/get

  @spec get_skill(module(), map(), Context.t()) :: term()
  def get_skill(server, %{"uri" => uri} = params, ctx) when is_binary(uri) do
    with {:ok, spec} <- find_or_error(server, uri, ctx),
         :ok <- Dispatch.listed(:skills, spec, params, ctx),
         :ok <- Server.permit(spec, ctx) do
      {:ok,
       %{"skill" => Skill.to_wire(spec.skill)}
       |> Dispatch.cacheable(server, ctx, [spec.ttl])
       |> Middleware.cache_scope(server, [:after_list])
       |> cache_scope(server)}
    end
  end

  def get_skill(_server, _params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "skills/get needs a uri"}

  defp find_or_error(server, uri, ctx) do
    case find(server, uri, ctx) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, JSONRPC.code(:invalid_params), "No skill is served at #{uri}"}
    end
  end

  # ---- resources/read of a skill's file

  @doc """
  The contents of the skill's file at `uri`, as a `resources/read`
  result: text when the file is UTF-8, a blob otherwise, so that the
  bytes the client gets are the ones the manifest's digest covers.
  """
  @spec read(Sake.Resource.Spec.t(), String.t(), Context.t()) ::
          {:ok, map(), pos_integer() | nil} | {:error, :not_found} | term()
  def read(%{skill: %{proxy: proxy} = spec}, uri, ctx) when proxy != nil do
    {:ok, inner} = Mount.inner_uri(spec, uri)

    case Sake.Proxy.Forward.read(%Sake.Resource.Spec{proxy: proxy, uri: inner}, inner, ctx) do
      {:ok, result, ttl} ->
        contents = for c <- result["contents"], do: %{c | "uri" => outer(c["uri"], inner, uri)}
        {:ok, %{result | "contents" => contents}, ttl}

      other ->
        other
    end
  end

  def read(%{skill: spec} = resource, uri, ctx) do
    inner_spec = Mount.innermost(spec)
    {:ok, inner} = Mount.inner_uri(spec, uri)

    case content(inner_spec, inner, ctx) do
      {:ok, bytes} -> {:ok, %{"contents" => [contents(uri, bytes, resource.mime_type)]}, nil}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # The upstream answers for the URI it was asked; the client asked for
  # the outer one.
  defp outer(inner, inner, outer), do: outer
  defp outer(other, _inner, _outer), do: other

  defp content(%{skill: skill} = spec, uri, ctx) do
    case Map.fetch(skill.files, uri) do
      {:ok, bytes} ->
        {:ok, bytes}

      :error when skill.resources == :dynamic ->
        read_dynamic(spec, skill, uri, ctx)

      :error ->
        {:error, :not_found}
    end
  end

  defp read_dynamic(%{module: module, catalog: true}, skill, uri, ctx) do
    file = Map.get(skill.paths, uri) || String.replace_prefix(uri, Skill.root(skill) <> "/", "")

    if function_exported?(module, :read, 3) do
      case module.read(skill, file, ctx) do
        {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
        _ -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp read_dynamic(_spec, _skill, _uri, _ctx), do: {:error, :not_found}

  defp contents(uri, bytes, mime_type) do
    if String.valid?(bytes),
      do: %{"uri" => uri, "mimeType" => mime_type, "text" => bytes},
      else: %{"uri" => uri, "mimeType" => mime_type, "blob" => Base.encode64(bytes)}
  end

  # ---- resources/directory/read

  @spec read_directory(module(), map(), Context.t()) :: term()
  def read_directory(server, %{"uri" => uri} = params, ctx) when is_binary(uri) do
    with {:ok, spec, children} <- directory(server, uri, ctx),
         :ok <- Dispatch.listed(:skills, spec, params, ctx),
         :ok <- Server.permit(spec, ctx),
         {:ok, offset} <- Dispatch.offset(params, ctx) do
      {page, next} = Dispatch.page(children, offset, server)

      {:ok,
       %{"resources" => page}
       |> Dispatch.next_cursor(next, ctx)
       |> Dispatch.cacheable(server, ctx, [spec.ttl])
       |> Middleware.cache_scope(server, [:after_list])
       |> cache_scope(server)}
    end
  end

  def read_directory(_server, _params, _ctx),
    do: {:error, JSONRPC.code(:invalid_params), "resources/directory/read needs a uri"}

  # The skill a directory is in, and the directory's direct children:
  # its root, or a directory one of its files is in.
  defp directory(server, uri, ctx) do
    [uri | ancestors(uri)]
    |> Enum.find_value(fn dir ->
      with {:ok, spec} <- find(server, dir <> "/SKILL.md", ctx, false),
           [_ | _] = children <- children(file_uris(spec.skill), uri) do
        {:ok, spec, children}
      else
        _ -> nil
      end
    end)
    |> case do
      nil ->
        {:error, JSONRPC.code(:invalid_params), "#{uri} is not a directory resource",
         %{"uri" => uri}}

      found ->
        found
    end
  end

  defp children(uris, dir) do
    prefix = dir <> "/"

    uris
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(fn uri ->
      case String.split(String.replace_prefix(uri, prefix, ""), "/", parts: 2) do
        [name] -> %{"uri" => uri, "name" => name, "mimeType" => mime_type(uri)}
        [name, _] -> %{"uri" => prefix <> name, "name" => name, "mimeType" => @directory}
      end
    end)
    |> Enum.uniq_by(& &1["uri"])
    |> Enum.sort_by(&{&1["mimeType"] == @directory, &1["uri"]})
  end
end
