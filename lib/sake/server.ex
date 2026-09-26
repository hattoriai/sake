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
      import Sake.Server, only: [scope: 2, tools: 1, resources: 1, prompts: 1]
      @before_compile Sake.Server
    end
  end

  defmacro scope(name, description),
    do: quote(do: @sake_scopes({unquote(name), unquote(description)}))

  defmacro tools(list), do: quote(do: @sake_tools(unquote(list)))
  defmacro resources(list), do: quote(do: @sake_resources(unquote(list)))
  defmacro prompts(list), do: quote(do: @sake_prompts(unquote(list)))

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :sake_opts)
    name = required!(opts, :name, env.module)
    version = required!(opts, :version, env.module)

    quote do
      @sake_specs Sake.Server.compile!(__MODULE__, @sake_tools, @sake_resources, @sake_prompts)

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
      def __sake__(:instructions), do: unquote(opts[:instructions])
    end
  end

  @doc false
  def list_defs do
    quote do
      def __sake__(:tools), do: elem(@sake_specs, 0)
      def __sake__(:resources), do: elem(@sake_specs, 1)
      def __sake__(:prompts), do: elem(@sake_specs, 2)
      def __sake__(:scopes), do: Enum.reverse(@sake_scopes)
    end
  end

  @doc false
  def setting_defs(opts) do
    quote do
      def __sake__(:ttl), do: unquote(opts[:ttl] || 300_000)
      def __sake__(:cache_scope), do: unquote(opts[:cache_scope])
      def __sake__(:page_size), do: unquote(opts[:page_size] || 100)
      def __sake__(:extensions), do: unquote(Macro.escape(opts[:extensions] || %{}))
    end
  end

  @doc false
  def compile!(server, tools, resources, prompts) do
    t = Enum.map(tools, & &1.spec())
    r = Enum.map(resources, & &1.spec())
    p = Enum.map(prompts, & &1.spec())
    check_unique!(server, "tool", Enum.map(t, & &1.name))
    check_unique!(server, "resource", Enum.map(r, & &1.uri))
    check_unique!(server, "prompt", Enum.map(p, & &1.name))
    {t, r, p}
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
