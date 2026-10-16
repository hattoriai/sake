defmodule Sake.Server do
  @moduledoc """
  The server module lists the components and their scopes.

      defmodule MyApp.MCP do
        use Sake.Server, name: "myapp", version: "1.0.0", instructions: "..."
        scope "issues:read", "Read issues"
        tools [MyApp.MCP.SearchIssues]
        resources [MyApp.MCP.Issue]
        prompts [MyApp.MCP.Triage]
      end

  Options: `name`, `version` (required), `instructions`, `ttl` (default
  300 000 ms), `cache_scope` (`:public` or `:private`; default: private
  when the endpoint has authorization, public otherwise), `page_size`
  (default 100), `extensions` (a map for extension negotiation).

  On the modern protocol, list and read results carry `ttlMs`: the
  server's `ttl`, or less. A tool, resource or prompt with its own `ttl:`
  shortens the `ttlMs` of every list page that includes it, and a
  resource's `ttl:` also sets the `ttlMs` of its `resources/read` result
  (the shortest ttl always wins).

  `middleware event, plugs` runs host code around the server's calls
  (see `Sake.Middleware`); declare it once or more per event, and the
  plugs run in the order declared:

      middleware :before_call, [MyApp.MCP.Audit, {MyApp.MCP.Tenant, field: :org_id}]

  `mount server, opts` makes another server's tools, resources and prompts
  this server's, so that each team or context can own its part of a large
  server:

      mount MyApp.MCP.Billing, prefix: "billing", scope: "billing"

  With `prefix:`, tool and prompt names take the prefix and an underscore
  (`billing_create_invoice`) and resource URIs take it as the first
  segment after the scheme (`invoice://billing/{id}`, `ui://billing/board`);
  `scope:` (one or many) adds required scopes to every component mounted.
  See `guides/composing.md` for what the mounted server's own middleware,
  instructions, scopes and settings become.
  """

  @callback __sake__(atom()) :: term()

  defmacro __using__(opts) do
    quote do
      @behaviour Sake.Server
      @sake_opts unquote(opts)
      @sake_tools []
      @sake_resources []
      @sake_prompts []
      Module.register_attribute(__MODULE__, :sake_scopes, accumulate: true)
      Module.register_attribute(__MODULE__, :sake_middleware, accumulate: true)
      Module.register_attribute(__MODULE__, :sake_mounts, accumulate: true)

      import Sake.Server,
        only: [scope: 2, tools: 1, resources: 1, prompts: 1, middleware: 2, mount: 1, mount: 2]

      @before_compile Sake.Server
    end
  end

  defmacro scope(name, description),
    do: quote(do: @sake_scopes({unquote(name), unquote(description)}))

  defmacro tools(list), do: quote(do: @sake_tools(unquote(list)))
  defmacro resources(list), do: quote(do: @sake_resources(unquote(list)))
  defmacro prompts(list), do: quote(do: @sake_prompts(unquote(list)))

  defmacro middleware(event, plugs),
    do: quote(do: @sake_middleware({unquote(event), unquote(plugs)}))

  @doc """
  Mounts another server's tools, resources and prompts in this one.
  Options: `prefix:` and `scope:` (see the module documentation).
  """
  defmacro mount(server, opts \\ []),
    do: quote(do: @sake_mounts({unquote(server), unquote(opts)}))

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :sake_opts)
    name = required!(opts, :name, env.module)
    version = required!(opts, :version, env.module)

    quote do
      @sake_mounted Sake.Server.compile_mounts!(__MODULE__, Enum.reverse(@sake_mounts))

      @sake_specs Sake.Server.compile!(
                    __MODULE__,
                    @sake_tools,
                    @sake_resources,
                    @sake_prompts,
                    @sake_mounted
                  )

      @sake_pipelines Sake.Server.compile_middleware!(__MODULE__, Enum.reverse(@sake_middleware))

      @impl Sake.Server
      unquote(Sake.Server.info_defs(name, version, opts))
      unquote(Sake.Server.list_defs())
      unquote(Sake.Server.setting_defs(opts))
    end
  end

  defp required!(opts, key, module) do
    opts[key] || raise(ArgumentError, "#{inspect(module)}: a server needs a #{key}")
  end

  @doc false
  def info_defs(name, version, opts) do
    quote do
      def __sake__(:info), do: %{name: unquote(name), version: unquote(version)}

      def __sake__(:instructions),
        do: unquote(__MODULE__).instructions(unquote(opts[:instructions]), @sake_mounted)
    end
  end

  @doc false
  def list_defs do
    quote do
      def __sake__(:tools), do: elem(@sake_specs, 0)
      def __sake__(:resources), do: elem(@sake_specs, 1)
      def __sake__(:prompts), do: elem(@sake_specs, 2)

      def __sake__(:scopes),
        do: unquote(__MODULE__).scopes(Enum.reverse(@sake_scopes), @sake_mounted)

      def __sake__(:middleware), do: @sake_pipelines
      def __sake__(:mounts), do: @sake_mounted
    end
  end

  @doc false
  def setting_defs(opts) do
    quote do
      def __sake__(:ttl), do: unquote(opts[:ttl] || 300_000)
      def __sake__(:cache_scope), do: unquote(opts[:cache_scope])
      def __sake__(:page_size), do: unquote(opts[:page_size] || 100)

      def __sake__(:extensions),
        do:
          unquote(__MODULE__).extensions(
            unquote(Macro.escape(opts[:extensions] || %{})),
            @sake_mounted
          )
    end
  end

  @doc false
  # The servers mounted, each with its checked options.
  def compile_mounts!(parent, mounts) do
    Enum.map(mounts, fn {server, opts} ->
      if not (is_atom(server) and Code.ensure_compiled(server) == {:module, server} and
                function_exported?(server, :__sake__, 1)) do
        raise ArgumentError,
              "#{inspect(parent)}: mount needs a Sake.Server, got #{inspect(server)}"
      end

      {server, Sake.Server.Mount.options!(parent, server, opts)}
    end)
  end

  @doc false
  # The server's own components, then each mounted server's under its
  # prefix, checked together: a name may be listed once in all of them.
  def compile!(server, tools, resources, prompts, mounts \\ []) do
    t = Enum.map(tools, & &1.spec()) ++ mounted(mounts, :tools)
    r = Enum.map(resources, & &1.spec()) ++ mounted(mounts, :resources)
    p = Enum.map(prompts, & &1.spec()) ++ mounted(mounts, :prompts)
    check_unique!(server, "tool", Enum.map(t, & &1.name))
    check_unique!(server, "resource", Enum.map(r, & &1.uri))
    check_unique!(server, "prompt", Enum.map(p, & &1.name))
    check_uis!(server, t, r)
    {t, r, p}
  end

  defp mounted(mounts, kind) do
    for {server, opts} <- mounts,
        spec <- server.__sake__(kind),
        do: Sake.Server.Mount.wrap(spec, server, opts)
  end

  @doc false
  # The server's instructions, then each mounted server's, under a heading
  # that names its prefix: a mounted server's instructions speak of its
  # components by the names it gave them.
  def instructions(own, mounts) do
    mounted =
      for {server, opts} <- mounts, text = server.__sake__(:instructions), text != nil do
        if opts[:prefix], do: "## #{opts[:prefix]}\n\n" <> text, else: text
      end

    case Enum.reject([own | mounted], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  @doc false
  # The server's scopes and those of the servers it mounts: a scope
  # declared twice keeps its first description.
  def scopes(own, mounts) do
    mounted = for {server, _opts} <- mounts, scope <- server.__sake__(:scopes), do: scope
    extra = for {_server, opts} <- mounts, name <- opts[:scopes], do: {name, name}
    Enum.uniq_by(own ++ mounted ++ extra, &elem(&1, 0))
  end

  @doc false
  # The server's `extensions:`, with what the mounted servers declare
  # where it says nothing.
  def extensions(own, mounts),
    do:
      Enum.reduce(mounts, own, fn {server, _opts}, acc ->
        Map.merge(server.__sake__(:extensions), acc)
      end)

  @doc false
  # The middleware by event, each plug with what its `init/1` returned:
  # like a Plug's, `init/1` runs once, here, when the server compiles.
  def compile_middleware!(server, declarations) do
    Enum.reduce(declarations, %{}, fn {event, plugs}, acc ->
      if event not in Sake.Middleware.events() do
        raise ArgumentError,
              "#{inspect(server)}: #{inspect(event)} is not a middleware event; " <>
                "the events are #{inspect(Sake.Middleware.events())}"
      end

      entries = plugs |> List.wrap() |> Enum.map(&plug!(server, &1))
      Map.update(acc, event, entries, &(&1 ++ entries))
    end)
  end

  defp plug!(server, {module, opts}) when is_atom(module) do
    Code.ensure_compiled!(module)

    if not function_exported?(module, :call, 2) do
      raise ArgumentError, "#{inspect(server)}: middleware #{inspect(module)} has no call/2"
    end

    {module, if(function_exported?(module, :init, 1), do: module.init(opts), else: opts)}
  end

  defp plug!(server, module) when is_atom(module), do: plug!(server, {module, []})

  defp plug!(server, other) do
    raise ArgumentError,
          "#{inspect(server)}: middleware must be a module or {module, opts}, got #{inspect(other)}"
  end

  # A host fetches a tool's UI with resources/read, so the UI has to be
  # one of the server's resources.
  defp check_uis!(server, tools, resources) do
    uris = for %{ui: true, uri: uri} <- resources, do: uri

    case Enum.find(tools, &(&1.ui && &1.ui not in uris)) do
      nil ->
        :ok

      tool ->
        raise ArgumentError,
              "#{inspect(server)}: tool #{inspect(tool.name)} shows the UI #{inspect(tool.ui)}, " <>
                "which is not among the server's resources"
    end
  end

  defp check_unique!(server, kind, names) do
    case names -- Enum.uniq(names) do
      [] ->
        :ok

      [dup | _] ->
        raise ArgumentError, "#{inspect(server)}: #{kind} #{inspect(dup)} is listed twice"
    end
  end

  @spec tool(module(), String.t()) :: {:ok, Sake.Tool.Spec.t()} | :error
  def tool(server, name) do
    case Enum.find(server.__sake__(:tools), &(&1.name == name)) do
      nil -> :error
      spec -> {:ok, spec}
    end
  end

  @spec resource(module(), String.t()) :: {:ok, Sake.Resource.Spec.t(), map()} | :error
  def resource(server, uri) do
    Enum.find_value(server.__sake__(:resources), :error, fn spec ->
      case Sake.Resource.Spec.match(spec, uri) do
        {:ok, params} -> {:ok, spec, params}
        :error -> nil
      end
    end)
  end

  @spec prompt(module(), String.t()) :: {:ok, Sake.Prompt.Spec.t()} | :error
  def prompt(server, name) do
    case Enum.find(server.__sake__(:prompts), &(&1.name == name)) do
      nil -> :error
      spec -> {:ok, spec}
    end
  end

  @doc "Whether the request may see or call the component: no token means no gating."
  @spec allowed?(struct(), Sake.Context.t()) :: boolean()
  def allowed?(_spec, %Sake.Context{token: nil}), do: true
  def allowed?(%{scopes: required}, %Sake.Context{scopes: granted}), do: required -- granted == []

  @spec capabilities(module()) :: map()
  def capabilities(server) do
    tools = server.__sake__(:tools)
    resources = server.__sake__(:resources)
    prompts = server.__sake__(:prompts)
    all = tools ++ resources ++ prompts

    %{}
    |> then(&if(tools != [], do: Map.put(&1, "tools", %{"listChanged" => true}), else: &1))
    |> then(
      &if(resources != [],
        do:
          Map.put(&1, "resources", %{
            "listChanged" => true,
            "subscribe" => Enum.any?(resources, fn r -> r.subscribe end)
          }),
        else: &1
      )
    )
    |> then(&if(prompts != [], do: Map.put(&1, "prompts", %{"listChanged" => true}), else: &1))
    |> then(
      &if(
        Enum.any?(all, fn s ->
          Code.ensure_loaded?(s.module) and function_exported?(s.module, :complete, 3)
        end),
        do: Map.put(&1, "completions", %{}),
        else: &1
      )
    )
    |> Map.put("logging", %{})
  end

  @doc "Tells listening clients that the list of tools, resources or prompts changed."
  @spec notify_list_changed(module(), :tools | :resources | :prompts) :: :ok
  def notify_list_changed(server, kind) when kind in [:tools, :resources, :prompts] do
    Sake.Plug.Streams.broadcast(server, {:list_changed, kind})
  end

  @doc "Tells subscribed clients that a resource changed."
  @spec resource_updated(module(), String.t()) :: :ok
  def resource_updated(server, uri),
    do: Sake.Plug.Streams.broadcast(server, {:resource_updated, uri})
end
