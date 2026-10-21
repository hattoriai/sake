defmodule Sake.Tool do
  @moduledoc """
  A tool: `use Sake.Tool` with options, `arg` lines, an optional `output`
  block, and `execute/2`.

      defmodule MyApp.MCP.SearchIssues do
        use Sake.Tool, name: "search_issues", description: "Search issues", scope: "issues:read"
        arg :query, :string, required: true
        @impl true
        def execute(%{query: q}, ctx), do: {:ok, Issues.search(ctx.scope, q)}
      end

  Options: `name` (default: the module's last segment in snake case),
  `title`, `description`, `icons`, `scope` (one or many), `annotations`
  (`read_only`, `destructive`, `idempotent`, `open_world`), `stream`,
  `ttl`, `meta`, `input_schema` (a schema map instead of `arg` lines),
  `task` (`:optional` or `true`, or `:required`: the tool runs as a task
  for a client that takes one, see `Sake.Tasks`), `ui` (a `Sake.UI`
  module: the app the host shows with the tool's result), `visibility`
  (`[:model, :app]` by default; `[:app]` for a tool only an app calls,
  which a client without MCP Apps does not see), `authentication`
  (`[acr: ["mfa"], max_age: 300]`: how the person must have signed in
  to call it, see "Step-up authentication" in `Sake.Server`), `absent`
  (`:nil` by default: an optional argument the client left out is `nil`;
  `:omit`: it is left out, at every level, so `execute/2` gets what the
  client sent and tells a left-out argument from one sent as `null`, see
  `Sake.Schema.validate/3`).
  """

  alias Sake.Schema

  @callback spec() :: Sake.Tool.Spec.t()
  @callback execute(args :: map(), ctx :: Sake.Context.t()) ::
              {:ok, term()}
              | {:ok, term(), keyword()}
              | {:error, String.t()}
              | {:error, {:missing_capability, map()}}
  @callback complete(arg :: String.t(), partial :: String.t(), ctx :: Sake.Context.t()) ::
              {:ok, [String.t()]} | {:ok, [String.t()], keyword()}
  @doc """
  Runs before `execute/2`, in the request itself, and returns the
  arguments `execute/2` receives (or a tool error). A task tool asks the
  client for input here when the answer decides whether the task should
  start at all: inside the request, the question travels as a multi
  round-trip request; inside the task, it would wait on the task.
  """
  @callback prepare(args :: map(), ctx :: Sake.Context.t()) :: {:ok, map()} | {:error, String.t()}
  @optional_callbacks complete: 3, prepare: 2

  @name_re ~r/^[A-Za-z0-9_.\-]{1,128}$/

  defmodule Spec do
    @moduledoc """
    The compiled definition of a tool.

    `mount` is `nil` for a tool the server declares itself, and
    `{server, prefix, spec}` for one it mounted (`Sake.Server.mount/2`):
    the server it came from, the mount's prefix, and the spec as that
    server has it. `proxy` is the `Sake.Proxy` whose upstream serves a
    proxied tool; it has no `module`.
    """
    @type t :: %__MODULE__{}
    defstruct [
      :module,
      :name,
      :title,
      :description,
      :output_schema,
      :meta,
      :ui,
      icons: [],
      input_schema: %{},
      annotations: %{},
      scopes: [],
      authentication: nil,
      stream: false,
      ttl: nil,
      task: nil,
      visibility: [:model, :app],
      headers: %{},
      mount: nil,
      proxy: nil,
      absent: nil
    ]

    @spec to_wire(t(), String.t()) :: map()
    def to_wire(%__MODULE__{} = s, revision) do
      %{"name" => s.name, "description" => s.description || "", "inputSchema" => s.input_schema}
      |> maybe_put("annotations", annotations(s.annotations))
      |> maybe_put("title", if(revision >= "2025-06-18", do: s.title))
      |> maybe_put("outputSchema", if(revision >= "2025-06-18", do: s.output_schema))
      |> maybe_put("icons", if(revision >= "2025-11-25", do: Sake.Tool.icons_to_wire(s.icons)))
      |> maybe_put("_meta", s.meta)
    end

    defp annotations(a) when a == %{}, do: nil

    defp annotations(a) do
      Map.new(a, fn
        {:read_only, v} -> {"readOnlyHint", v}
        {:destructive, v} -> {"destructiveHint", v}
        {:idempotent, v} -> {"idempotentHint", v}
        {:open_world, v} -> {"openWorldHint", v}
        {:title, v} -> {"title", v}
      end)
    end

    defp maybe_put(m, _k, nil), do: m
    defp maybe_put(m, _k, []), do: m
    defp maybe_put(m, k, v), do: Map.put(m, k, v)
  end

  defmacro __using__(opts) do
    quote do
      @behaviour Sake.Tool
      @sake_opts unquote(opts)
      Module.register_attribute(__MODULE__, :sake_args, accumulate: true)
      Module.register_attribute(__MODULE__, :sake_output_args, accumulate: true)
      @sake_in_output false
      import Sake.Tool, only: [arg: 2, arg: 3, output: 1]
      @before_compile Sake.Tool
    end
  end

  @doc "Declares an argument (or, inside `output`, an output property)."
  defmacro arg(name, type, opts \\ []) do
    quote do
      if @sake_in_output,
        do: @sake_output_args({unquote(name), unquote(type), unquote(opts)}),
        else: @sake_args({unquote(name), unquote(type), unquote(opts)})
    end
  end

  @doc "Declares the output schema with `arg` lines."
  defmacro output(do: block) do
    quote do
      @sake_in_output true
      unquote(block)
      @sake_in_output false
    end
  end

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :sake_opts)
    args = env.module |> Module.get_attribute(:sake_args) |> Enum.reverse()
    output_args = env.module |> Module.get_attribute(:sake_output_args) |> Enum.reverse()
    name = validate_name!(opts[:name] || default_name(env.module))
    spec = build_spec(env.module, name, opts, args, output_args)

    quote do
      @impl Sake.Tool
      def spec, do: unquote(Macro.escape(spec))
    end
  end

  @doc false
  def validate_name!(name) do
    unless is_binary(name) and Regex.match?(@name_re, name),
      do:
        raise(
          ArgumentError,
          "tool name #{inspect(name)} must be 1-128 characters of letters, digits, _ . -"
        )

    name
  end

  defp build_spec(module, name, opts, args, output_args) do
    input_schema = opts[:input_schema] || Schema.build(args)
    output_schema = opts[:output_schema] || output_schema(output_args)

    %Spec{
      module: module,
      name: name,
      title: opts[:title],
      description: opts[:description],
      icons: opts[:icons] || [],
      input_schema: input_schema,
      output_schema: output_schema,
      annotations: Map.new(opts[:annotations] || []),
      scopes: List.wrap(opts[:scope]),
      authentication:
        Sake.Auth.Authentication.requirement!(opts[:authentication], inspect(module)),
      stream: opts[:stream] || false,
      ttl: opts[:ttl],
      task: task_support!(module, opts[:task]),
      meta: opts[:meta],
      ui: ui_uri!(module, opts[:ui]),
      visibility: visibility!(module, opts[:visibility]),
      headers: Schema.header_paths(input_schema),
      absent: absent!(module, opts[:absent])
    }
  end

  defp absent!(_module, absent) when absent in [nil, nil, :omit], do: absent

  defp absent!(module, other),
    do:
      raise(
        ArgumentError,
        "#{inspect(module)}: absent: must be :nil or :omit, got #{inspect(other)}"
      )

  defp task_support!(_module, nil), do: nil
  defp task_support!(_module, false), do: nil
  defp task_support!(_module, true), do: :optional
  defp task_support!(_module, support) when support in [:optional, :required], do: support

  defp task_support!(module, other),
    do:
      raise(
        ArgumentError,
        "#{inspect(module)}: task: must be :optional or :required, got #{inspect(other)}"
      )

  # The tool keeps its UI's URI, which is what travels in its `_meta.ui`.
  defp ui_uri!(_module, nil), do: nil

  defp ui_uri!(module, ui) do
    with true <- is_atom(ui) and Code.ensure_compiled(ui) == {:module, ui},
         true <- function_exported?(ui, :spec, 0),
         %Sake.Resource.Spec{ui: true, uri: uri} <- ui.spec() do
      uri
    else
      _ -> raise ArgumentError, "#{inspect(module)}: ui: #{inspect(ui)} is not a Sake.UI"
    end
  end

  defp visibility!(_module, nil), do: [:model, :app]

  defp visibility!(module, visibility) do
    if is_list(visibility) and visibility != [] and visibility -- [:model, :app] == [],
      do: Enum.uniq(visibility),
      else:
        raise(
          ArgumentError,
          "#{inspect(module)}: visibility: must list :model, :app or both, got #{inspect(visibility)}"
        )
  end

  defp output_schema([]), do: nil
  defp output_schema(output_args), do: Schema.build(output_args)

  @doc false
  def default_name(module), do: module |> Module.split() |> List.last() |> Macro.underscore()

  @doc false
  def icons_to_wire([]), do: nil

  def icons_to_wire(icons) do
    Enum.map(icons, fn icon ->
      %{"src" => icon[:src]}
      |> then(&if(icon[:mime_type], do: Map.put(&1, "mimeType", icon[:mime_type]), else: &1))
      |> then(&if(icon[:sizes], do: Map.put(&1, "sizes", icon[:sizes]), else: &1))
      |> then(&if(icon[:theme], do: Map.put(&1, "theme", to_string(icon[:theme])), else: &1))
    end)
  end
end
