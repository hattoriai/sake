defmodule Sake.Extension do
  @moduledoc ~S"""
  An MCP extension (SEP-2133): methods, settings and notifications a
  server adds to the protocol under an identifier of its own, which a
  client negotiates by declaring the identifier in its capabilities.

      defmodule Widgets.MCP.Extension do
        use Sake.Extension, id: "com.example/widgets", scope: "widgets:read"

        method "widgets/list"
        method "widgets/delete", scope: "widgets:write"
        notification "notifications/widgets/changed"

        @impl true
        def settings(_server), do: %{"maxPageSize" => 50}

        @impl true
        def handle("widgets/list", _params, ctx),
          do: {:ok, %{"widgets" => Widgets.all(ctx.scope)}}

        def handle("widgets/delete", %{"id" => id}, ctx) do
          :ok = Widgets.delete(ctx.scope, id)
          Sake.Extension.notify(ctx.server, __MODULE__, "notifications/widgets/changed", %{})
          {:ok, %{}}
        end

        def handle("widgets/delete", _params, _ctx),
          do: {:error, -32602, "widgets/delete needs an id"}
      end

      defmodule MyApp.MCP do
        use Sake.Server, name: "my-app", version: "1.0.0"
        extensions [Widgets.MCP.Extension]
      end

  An extension can live in a package of its own that depends on Sake;
  a host that does not list it pays nothing for it.

  ## Options

    * `:id` (required) — the extension's identifier, `vendor-prefix/name`
      (`com.example/widgets`), as SEP-2133 has it. Identifiers under
      `io.modelcontextprotocol/` are the protocol's own.
    * `:scope` and `:authentication` — what every method requires, as a
      tool's do (see "Step-up authentication" in `Sake.Server`); a
      `method` adds its own.
    * `:client` — `:optional` (the default): any client may call the
      methods; `:required`: a client that did not declare the extension
      in its capabilities gets `-32021` (missing capability) naming it.
    * `:since` — the oldest protocol revision the extension is served on
      (say `"2026-07-28"`): on an older one it is not advertised and its
      methods are unknown. Served on every revision by default.
    * `:result_types` — the `resultType`s besides `"complete"` a result
      may carry, for an extension that defines its own; one is sent only
      to a client that declared the extension.

  ## Methods and results

  `method name, opts` declares a method (`scope:` and `authentication:`
  add to the extension's); `handle/3` answers it with the request's
  params (string keys, `_meta` included) and the `Sake.Context`:

    * `{:ok, result}` — the result map. On 2026-07-28 Sake adds
      `resultType: "complete"` (unless the result names one of
      `:result_types`) and the server info in `_meta`, as for a core
      method. `cacheable/2` adds `ttlMs` and `cacheScope`.
    * `{:error, code, message}` or `{:error, code, message, data}` — a
      JSON-RPC error.
    * `{:error, {:missing_capability, capabilities}}` — `-32021`.

  An exception in `handle/3` is logged and answered with `-32603`, as a
  failing tool is. A method's name may not be one the protocol or Sake
  serves (`tools/list`, `skills/get`, `notifications/...`), nor another
  listed extension's: either is a compile error.

  ## What a request goes through

  An extension method is dispatched as a core one: the same endpoint
  (`Sake.Plug`, `Sake.Stdio`, `Sake.Test`), the `:before_request`
  middleware (whose payload has the `method` and `params`), the
  scopes and authentication of its `method` (a 403 or 401 the client
  can step up from), the `[:sake, :server, :request]` telemetry span and
  the trace. Over HTTP the `Mcp-Method` header must name it, as for any
  request.

  ## Notifications

  `notification name` declares a notification the extension sends;
  `notify/4` broadcasts one to the server's clients. On 2026-07-28 a
  client receives them on a `subscriptions/listen` stream whose
  `notifications` filter has the extension's identifier set to `true`;
  a legacy session's stream (HTTP or stdio) receives them all.

  ## Mounting and proxies

  A mounted server's extensions are the server's that mounts it. Method
  names are the extension's, not renamed by a prefix: two extensions
  with the same method, from any of the servers mounted, are a compile
  error, and one extension listed by two mounted servers is served once,
  by the first. `handle/3` runs with its own server in `ctx.server` and
  the mounts' prefixes in `ctx.prefixes`; the mount's `scope:` and the
  mounted server's `authentication:` apply to its methods.

  A `Sake.Proxy` forwards no extension: it does not advertise its
  upstream's extensions (other than those Sake implements, such as
  tasks, MCP Apps and, with `skills: true`, skills) and answers their
  methods as unknown. An extension the proxy module lists itself is
  served by the proxy, as by any server.
  """

  alias Sake.Extension.{Method, Spec}

  @typedoc "What `handle/3` returns."
  @type result ::
          {:ok, map()}
          | {:error, integer(), String.t()}
          | {:error, integer(), String.t(), term()}
          | {:error, {:missing_capability, map()}}

  @doc "The extension's settings, advertised under its identifier. `%{}` by default."
  @callback settings(server :: module()) :: map()

  @doc "Answers one of the extension's methods."
  @callback handle(method :: String.t(), params :: map(), ctx :: Sake.Context.t()) :: result()

  @optional_callbacks settings: 1

  @id_re ~r/^[A-Za-z0-9]([A-Za-z0-9\-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9\-]*[A-Za-z0-9])?)*\/[A-Za-z0-9][A-Za-z0-9._\-]*$/
  @method_re ~r/^[A-Za-z0-9][A-Za-z0-9_.\-]*(\/[A-Za-z0-9][A-Za-z0-9_.\-]*)+$/

  defmacro __using__(opts) do
    quote do
      @behaviour Sake.Extension
      @sake_extension_opts unquote(opts)
      Module.register_attribute(__MODULE__, :sake_extension_methods, accumulate: true)
      Module.register_attribute(__MODULE__, :sake_extension_notifications, accumulate: true)
      import Sake.Extension, only: [method: 1, method: 2, notification: 1]
      @before_compile Sake.Extension
    end
  end

  @doc "Declares one of the extension's methods; see the module documentation."
  defmacro method(name, opts \\ []),
    do: quote(do: @sake_extension_methods({unquote(name), unquote(opts)}))

  @doc "Declares a notification the extension sends; see `notify/4`."
  defmacro notification(name),
    do: quote(do: @sake_extension_notifications(unquote(name)))

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :sake_extension_opts)
    methods = env.module |> Module.get_attribute(:sake_extension_methods) |> Enum.reverse()

    notifications =
      env.module |> Module.get_attribute(:sake_extension_notifications) |> Enum.reverse()

    spec = build!(env.module, opts, methods, notifications)

    quote do
      @doc false
      def __sake_extension__, do: unquote(Macro.escape(spec))
    end
  end

  @doc false
  def build!(module, opts, methods, notifications) do
    where = inspect(module)
    check_options!(where, opts)

    scopes = List.wrap(opts[:scope])
    authentication = Sake.Auth.Authentication.requirement!(opts[:authentication], where)
    methods = Enum.map(methods, &method!(where, module, opts[:id], scopes, authentication, &1))

    if methods == [] and notifications == [] do
      raise ArgumentError, "#{where}: an extension needs a method or a notification"
    end

    case Enum.map(methods, & &1.name) -- Enum.uniq(Enum.map(methods, & &1.name)) do
      [] -> :ok
      [dup | _] -> raise ArgumentError, "#{where}: the method #{inspect(dup)} is declared twice"
    end

    %Spec{
      id: opts[:id],
      module: module,
      methods: methods,
      notifications: notifications,
      client: opts[:client] || :optional,
      since: opts[:since],
      result_types: List.wrap(opts[:result_types])
    }
  end

  defp check_options!(where, opts) do
    id = opts[:id]

    case Keyword.keys(opts) -- [:id, :scope, :authentication, :client, :since, :result_types] do
      [] -> :ok
      keys -> raise ArgumentError, "#{where}: use Sake.Extension does not take #{inspect(keys)}"
    end

    check_id!(where, id)

    cond do
      opts[:client] not in [nil, :optional, :required] ->
        raise ArgumentError, "#{where}: client: must be :optional or :required"

      opts[:since] != nil and not Sake.Protocol.supported?(opts[:since]) ->
        raise ArgumentError,
              "#{where}: since: #{inspect(opts[:since])} is not a revision Sake speaks"

      true ->
        :ok
    end
  end

  defp check_id!(where, id) do
    cond do
      not (is_binary(id) and Regex.match?(@id_re, id)) ->
        raise ArgumentError,
              "#{where}: an extension needs an id: of the form vendor-prefix/name " <>
                "(com.example/widgets), got #{inspect(id)}"

      String.starts_with?(id, "io.modelcontextprotocol/") ->
        raise ArgumentError, "#{where}: the id #{inspect(id)} is the protocol's own"

      true ->
        :ok
    end
  end

  defp method!(where, module, id, scopes, authentication, {name, method_opts}) do
    if not (is_binary(name) and Regex.match?(@method_re, name)) do
      raise ArgumentError,
            "#{where}: a method is a name with at least one /, got #{inspect(name)}"
    end

    %Method{
      name: name,
      module: module,
      id: id,
      scopes: Enum.uniq(scopes ++ List.wrap(method_opts[:scope])),
      authentication:
        Sake.Auth.Authentication.merge!(
          Sake.Auth.Authentication.requirement!(method_opts[:authentication], where),
          authentication,
          where
        )
    }
  end

  @doc """
  Whether the request's client declared the extension `id`: in the
  request's capabilities on 2026-07-28, in its `initialize` on a legacy
  session.
  """
  @spec declared?(Sake.Context.t(), String.t()) :: boolean()
  def declared?(%Sake.Context{client_capabilities: caps}, id) do
    match?(%{"extensions" => %{^id => %{}}}, caps || %{})
  end

  @doc """
  Broadcasts one of the extension's notifications to `server`'s clients
  (on every node, with a pubsub): `extension` is the module or its
  identifier, `method` one of its `notification`s. Raises for a method
  the extension does not declare.
  """
  @spec notify(module(), module() | String.t(), String.t(), map()) :: :ok
  def notify(server, extension, method, params \\ %{}) when is_map(params) do
    spec = spec!(server, extension)

    if method not in spec.notifications do
      raise ArgumentError,
            "#{inspect(spec.module)} declares no notification #{inspect(method)}"
    end

    Sake.Plug.Streams.broadcast(server, {:extension, spec.id, method, params})
  end

  defp spec!(server, extension) do
    found =
      Enum.find(Sake.Server.Extensions.specs(server), fn spec ->
        spec.module == extension or spec.id == extension
      end)

    found || raise ArgumentError, "#{inspect(server)} serves no extension #{inspect(extension)}"
  end

  @doc """
  The result with `ttlMs` and `cacheScope` on 2026-07-28, from the
  server's `ttl` and cache scope, as a core list's (a no-op on a legacy
  session). Options: `ttl:` (ms), shorter than the server's.
  """
  @spec cacheable(map(), Sake.Context.t(), keyword()) :: map()
  def cacheable(result, %Sake.Context{} = ctx, opts \\ []),
    do: Sake.Server.Dispatch.cacheable(result, ctx.server, ctx, [opts[:ttl]])
end
