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
  (default 100), `extensions` (a map advertised as the server's
  extension capabilities, for an extension Sake does not implement; to
  implement one, see `Sake.Extension` and `extensions/1`),
  `authentication` (how the person must have signed in to call a tool,
  read a resource or get a prompt of this server, see below).

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
  `only:` or `except:` (a list of the mounted server's components, each a
  module, a tool or prompt name, or a resource URI, as that server
  declares it) mounts some of them:

      mount MyApp.MCP.Billing, prefix: "billing", except: [MyApp.MCP.Billing.Refund]

  See `guides/composing.md` for what the mounted server's own middleware,
  instructions, scopes and settings become. A `Sake.Proxy` mounts as any
  server does, with the components of its upstream.

  ## Step-up authentication

  A tool, resource or prompt with `authentication: [acr: ["mfa"],
  max_age: 300]` needs a token whose person signed in with one of those
  authentication context classes (`acr`), at most that many seconds ago
  (`max_age`), either optional (RFC 9470). The server's own
  `authentication:` applies to all its components, its mounted servers'
  too: an `acr` must then be among both lists, and the shorter `max_age`
  wins. A token that does not meet it is refused with a 401 whose
  `insufficient_user_authentication` challenge carries `acr_values` and
  `max_age`, for the client to have the person sign in again; a token
  that lacks the component's scopes as well gets that challenge, naming
  the scopes too, so that one new grant covers both. The components stay
  in the lists, and a request without a token (an endpoint without
  `auth:`, stdio) is not gated, as for scopes. A requirement that
  depends on the arguments is a middleware's: see
  `Sake.Middleware.require_authentication/2`. `max_age: 0` means a
  sign-in within the last minute. It gates a tool call, a resource read
  and a prompt get; lists, completions, subscriptions and the requests
  that follow a task (which was checked when it started) are not.
  """

  require Logger

  @callback __sake__(atom()) :: term()

  defmacro __using__(opts) do
    quote do
      @behaviour Sake.Server
      @sake_opts unquote(opts)
      @sake_tools []
      @sake_resources []
      @sake_prompts []
      @sake_skills []
      @sake_extensions []
      Module.register_attribute(__MODULE__, :sake_scopes, accumulate: true)
      Module.register_attribute(__MODULE__, :sake_middleware, accumulate: true)
      Module.register_attribute(__MODULE__, :sake_mounts, accumulate: true)
      # Set by `use Sake.Proxy`: the server's upstream is one of its sources.
      @sake_proxy false

      import Sake.Server,
        only: [
          scope: 2,
          tools: 1,
          resources: 1,
          prompts: 1,
          skills: 1,
          extensions: 1,
          middleware: 2,
          mount: 1,
          mount: 2
        ]

      @before_compile Sake.Server
    end
  end

  defmacro scope(name, description),
    do: quote(do: @sake_scopes({unquote(name), unquote(description)}))

  defmacro tools(list), do: quote(do: @sake_tools(unquote(list)))
  defmacro resources(list), do: quote(do: @sake_resources(unquote(list)))
  defmacro prompts(list), do: quote(do: @sake_prompts(unquote(list)))

  @doc """
  The server's skills: `Sake.Skill` modules, each a skill packaged with
  the server, and `Sake.Skill.Catalog` modules, whose skills the host
  gives at runtime. See `guides/skills.md`.
  """
  defmacro skills(list), do: quote(do: @sake_skills(unquote(list)))

  @doc """
  The extensions the server implements: `Sake.Extension` modules, whose
  methods it answers and whose settings it advertises. See
  `guides/extensions.md`.
  """
  defmacro extensions(list), do: quote(do: @sake_extensions(unquote(list)))

  defmacro middleware(event, plugs),
    do: quote(do: @sake_middleware({unquote(event), unquote(plugs)}))

  @doc """
  Mounts another server's tools, resources and prompts in this one.
  Options: `prefix:`, `scope:`, and `only:` or `except:` (see the module
  documentation).
  """
  defmacro mount(server, opts \\ []),
    do: quote(do: @sake_mounts({unquote(server), unquote(opts)}))

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :sake_opts)
    name = required!(opts, :name, env.module)
    version = required!(opts, :version, env.module)

    quote do
      @sake_mounted Sake.Server.compile_mounts!(__MODULE__, Enum.reverse(@sake_mounts))

      @sake_authentication Sake.Auth.Authentication.requirement!(
                             @sake_opts[:authentication],
                             inspect(__MODULE__)
                           )

      @sake_specs Sake.Server.compile!(
                    __MODULE__,
                    @sake_tools,
                    @sake_resources,
                    @sake_prompts,
                    @sake_mounted,
                    @sake_authentication
                  )

      @sake_skill_specs Sake.Server.compile_skills!(
                          __MODULE__,
                          @sake_skills,
                          @sake_mounted,
                          @sake_authentication
                        )

      @sake_extension_specs Sake.Server.Extensions.compile!(
                              __MODULE__,
                              @sake_extensions,
                              @sake_mounted,
                              @sake_authentication,
                              @sake_opts[:extensions]
                            )

      @sake_pipelines Sake.Server.compile_middleware!(__MODULE__, Enum.reverse(@sake_middleware))

      @impl Sake.Server
      unquote(Sake.Server.info_defs(name, version, opts))
      unquote(Sake.Server.list_defs())
      unquote(Sake.Server.setting_defs(opts))
      unquote(Sake.Server.extension_defs())
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
      def __sake__(:skills), do: @sake_skill_specs

      def __sake__(:scopes),
        do: unquote(__MODULE__).scopes(Enum.reverse(@sake_scopes), @sake_mounted)

      def __sake__(:middleware), do: @sake_pipelines
      def __sake__(:mounts), do: @sake_mounted

      def __sake__(:sources),
        do: unquote(__MODULE__).sources(@sake_proxy, __MODULE__, @sake_mounted)
    end
  end

  @doc false
  def extension_defs do
    quote do
      def __sake__(:extension_specs), do: @sake_extension_specs
    end
  end

  @doc false
  def setting_defs(opts) do
    quote do
      def __sake__(:ttl), do: unquote(opts[:ttl] || 300_000)
      def __sake__(:cache_scope), do: unquote(opts[:cache_scope])
      def __sake__(:page_size), do: unquote(opts[:page_size] || 100)

      def __sake__(:authentication), do: @sake_authentication

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
  # The server's `authentication:` (`required`) goes on every one.
  def compile!(server, tools, resources, prompts, mounts \\ [], required \\ nil) do
    t = authenticated(Enum.map(tools, & &1.spec()) ++ mounted(mounts, :tools), required, server)

    r =
      authenticated(
        Enum.map(resources, & &1.spec()) ++ mounted(mounts, :resources),
        required,
        server
      )

    p =
      authenticated(Enum.map(prompts, & &1.spec()) ++ mounted(mounts, :prompts), required, server)

    check_unique!(server, "tool", Enum.map(t, & &1.name))
    check_unique!(server, "resource", Enum.map(r, & &1.uri))
    check_unique!(server, "prompt", Enum.map(p, & &1.name))
    check_uis!(server, t, r)
    {t, r, p}
  end

  @doc false
  # The server's skills, then each mounted server's under its prefix: a
  # skill's URI may be listed once in all of them.
  def compile_skills!(server, skills, mounts \\ [], required \\ nil) do
    own =
      Enum.map(skills, fn module ->
        Code.ensure_compiled!(module)

        if not function_exported?(module, :spec, 0) or
             not match?(%Sake.Skill.Spec{}, module.spec()) do
          raise ArgumentError,
                "#{inspect(server)}: skills takes Sake.Skill and Sake.Skill.Catalog modules, " <>
                  "got #{inspect(module)}"
        end

        module.spec()
      end)

    specs = authenticated(own ++ mounted(mounts, :skills), required, server)
    check_unique!(server, "skill", for(%{uri: uri} <- specs, uri != nil, do: uri))
    check_unique!(server, "skill", for(%{catalog: true, mount: nil} = s <- specs, do: s.module))
    specs
  end

  # The server's `authentication:`, for every component it lists.
  defp authenticated(specs, nil, _server), do: specs

  defp authenticated(specs, required, server) do
    Enum.map(specs, fn spec ->
      where = "#{inspect(server)}: #{inspect(key(spec))}"

      %{
        spec
        | authentication: Sake.Auth.Authentication.merge!(spec.authentication, required, where)
      }
    end)
  end

  defp mounted(mounts, kind) do
    for {server, opts} <- mounts,
        spec <- server.__sake__(kind),
        Sake.Server.Mount.keep?(spec, opts),
        do: Sake.Server.Mount.wrap(spec, server, opts)
  end

  @doc false
  # The proxies whose upstream components the server lists, each with the
  # mounts between it and the server, innermost first: the proxy's own
  # (when the server is one) and those of the servers it mounts.
  def sources(proxy?, module, mounts) do
    own = if proxy?, do: [{module, []}], else: []

    own ++
      for {server, opts} <- mounts,
          {proxy, chain} <- server.__sake__(:sources),
          do: {proxy, chain ++ [{server, opts}]}
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

  @doc """
  The server's tools as the request sees them: its own and its mounted
  servers', then those its proxies (`Sake.Proxy`) list for the request's
  principal. A proxied tool whose name is already taken is left out: an
  upstream never shadows a local component.
  """
  @spec tools(module(), Sake.Context.t()) :: [Sake.Tool.Spec.t()]
  def tools(server, ctx), do: components(server, :tools, ctx)

  @doc """
  The server's skills as the request sees them: its own and its mounted
  servers', each catalog's (`Sake.Skill.Catalog`) for the request, and
  those its proxies list. A skill whose URI is already taken is left out.
  """
  @spec skills(module(), Sake.Context.t()) :: [Sake.Skill.Spec.t()]
  def skills(server, ctx), do: Sake.Server.Skills.list(server, ctx)

  @doc "The server's resources as the request sees them; see `tools/2`."
  @spec resources(module(), Sake.Context.t()) :: [Sake.Resource.Spec.t()]
  def resources(server, ctx), do: components(server, :resources, ctx)

  @doc "The server's prompts as the request sees them; see `tools/2`."
  @spec prompts(module(), Sake.Context.t()) :: [Sake.Prompt.Spec.t()]
  def prompts(server, ctx), do: components(server, :prompts, ctx)

  defp components(server, kind, ctx) do
    static = server.__sake__(kind)

    case server.__sake__(:sources) do
      [] -> static
      sources -> static ++ server_authentication(server, dynamic(sources, kind, static, ctx))
    end
  end

  # A proxy's components are known at runtime: the server's
  # `authentication:` is put on them then, as `compile!/6` puts it on
  # the others.
  defp server_authentication(server, specs) do
    case server.__sake__(:authentication) do
      nil ->
        specs

      required ->
        Enum.map(
          specs,
          &%{&1 | authentication: Sake.Auth.Authentication.merge(&1.authentication, required)}
        )
    end
  end

  defp dynamic(sources, kind, static, ctx) do
    {specs, _taken} =
      Enum.reduce(sources, {[], MapSet.new(static, &key/1)}, fn {proxy, chain}, {acc, taken} ->
        {fresh, taken} =
          proxy
          |> Sake.Proxy.components(kind, ctx)
          |> Enum.flat_map(&wrap_chain(&1, chain))
          |> Enum.reduce({[], taken}, &unshadowed(&1, &2, server_of(chain, proxy)))

        {acc ++ Enum.reverse(fresh), taken}
      end)

    specs
  end

  defp unshadowed(spec, {fresh, taken}, proxy) do
    if MapSet.member?(taken, key(spec)) do
      Logger.debug(
        "#{inspect(proxy)}: left out the upstream's #{inspect(key(spec))}, a name already taken"
      )

      {fresh, taken}
    else
      {[spec | fresh], MapSet.put(taken, key(spec))}
    end
  end

  defp server_of([], proxy), do: proxy
  defp server_of(chain, _proxy), do: chain |> List.last() |> elem(0)

  @doc false
  # A proxied component through the mounts between its proxy and the
  # server; one whose name or URI a prefix cannot take is left out.
  def wrap_chain(spec, chain) do
    Enum.reduce_while(chain, [spec], fn {server, opts}, [spec] ->
      case Sake.Server.Mount.try_wrap(spec, server, opts) do
        {:ok, spec} -> {:cont, [spec]}
        :error -> {:halt, []}
      end
    end)
  end

  defp key(%Sake.Resource.Spec{uri: uri}), do: uri
  defp key(%Sake.Skill.Spec{uri: nil, module: module}), do: module
  defp key(%Sake.Skill.Spec{uri: uri}), do: uri
  defp key(%{name: name}), do: name

  @doc """
  The tool named `name`: one of the server's own (`tool/2`), or, with the
  request's context, one its proxies list for the request (`tools/2`).
  """
  @spec tool(module(), String.t(), Sake.Context.t() | nil) :: {:ok, Sake.Tool.Spec.t()} | :error
  def tool(server, name, ctx \\ nil) do
    case Enum.find(server.__sake__(:tools), &(&1.name == name)) do
      nil -> dynamic_find(server, :tools, name, ctx)
      spec -> {:ok, spec}
    end
  end

  @doc """
  The resource `uri` names, and the template's parameters: one of the
  server's own, or, with the request's context, one of its proxies'. A
  proxy serves what its upstream lists, and any other URI under its
  mount's prefix (a resource link in a proxied result, say), which its
  upstream answers for.
  """
  @spec resource(module(), String.t(), Sake.Context.t() | nil) ::
          {:ok, Sake.Resource.Spec.t(), map()} | :error
  def resource(server, uri, ctx \\ nil) do
    Enum.find_value(server.__sake__(:resources), :error, fn spec ->
      case Sake.Resource.Spec.match(spec, uri) do
        {:ok, params} -> {:ok, spec, params}
        :error -> nil
      end
    end)
    |> case do
      :error when ctx != nil -> dynamic_resource(server, uri, ctx)
      found -> found
    end
  end

  @doc "The prompt named `name`; see `tool/3`."
  @spec prompt(module(), String.t(), Sake.Context.t() | nil) ::
          {:ok, Sake.Prompt.Spec.t()} | :error
  def prompt(server, name, ctx \\ nil) do
    case Enum.find(server.__sake__(:prompts), &(&1.name == name)) do
      nil -> dynamic_find(server, :prompts, name, ctx)
      spec -> {:ok, spec}
    end
  end

  defp dynamic_find(_server, _kind, _name, nil), do: :error

  defp dynamic_find(server, kind, name, ctx) do
    case server.__sake__(:sources) do
      [] ->
        :error

      sources ->
        case Enum.find(dynamic(sources, kind, server.__sake__(kind), ctx), &(&1.name == name)) do
          nil -> :error
          spec -> {:ok, hd(server_authentication(server, [spec]))}
        end
    end
  end

  # The proxy whose namespace the URI is in: the first whose prefixes it
  # carries and whose upstream lists it, or, among the proxies mounted
  # under a prefix the URI carries (or the first without any), the one
  # that claims every URI it is given.
  defp dynamic_resource(server, uri, ctx) do
    sources = server.__sake__(:sources)

    with :error <- find_dynamic_resource(sources, uri, ctx, false),
         :error <- find_dynamic_resource(claimants(sources), uri, ctx, true) do
      :error
    else
      {:ok, spec, params} -> {:ok, hd(server_authentication(server, [spec])), params}
    end
  end

  defp claimants(sources) do
    {prefixed, bare} = Enum.split_with(sources, fn {_proxy, chain} -> prefixed?(chain) end)
    prefixed ++ Enum.take(bare, 1)
  end

  defp prefixed?(chain), do: Enum.any?(chain, fn {_server, opts} -> opts[:prefix] != nil end)

  defp find_dynamic_resource(sources, uri, ctx, claim?) do
    Enum.find_value(sources, :error, fn {proxy, chain} ->
      with {:ok, inner} <- unwrap_uri(chain, uri),
           {:ok, spec} <- Sake.Proxy.resource(proxy, inner, ctx, claim?),
           [spec] <- wrap_chain(spec, chain) do
        {:ok, spec, %{}}
      else
        _ -> nil
      end
    end)
  end

  @doc false
  def unwrap_uri(chain, uri) do
    chain
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, uri}, fn {_server, opts}, {:ok, uri} ->
      case Sake.Server.Mount.unuri(opts[:prefix], uri) do
        {:ok, uri} -> {:cont, {:ok, uri}}
        :error -> {:halt, :error}
      end
    end)
  end

  @doc "Whether the request may see or call the component: no token means no gating."
  @spec allowed?(struct(), Sake.Context.t()) :: boolean()
  def allowed?(_spec, %Sake.Context{token: nil}), do: true
  def allowed?(%{scopes: required}, %Sake.Context{scopes: granted}), do: required -- granted == []

  @doc false
  # Whether the request may call the component (a tool call, a resource
  # read, a prompt get): its scopes, and how the token's person signed in
  # (RFC 9470). A token that lacks both is refused for its sign-in, with
  # the scopes it lacks: the client's new grant then covers both, where
  # refusing the scopes first would leave it a second step-up to take.
  @spec permit(struct(), Sake.Context.t()) ::
          :ok
          | {:forbidden, [String.t()]}
          | {:insufficient_user_authentication, map()}
  def permit(spec, ctx) do
    scoped? = allowed?(spec, ctx)

    case authenticate(Map.get(spec, :authentication), ctx) do
      :ok when scoped? ->
        :ok

      :ok ->
        {:forbidden, spec.scopes}

      {:insufficient_user_authentication, refusal} ->
        {:insufficient_user_authentication,
         %{refusal | scopes: if(scoped?, do: [], else: spec.scopes)}}
    end
  end

  @doc false
  # Whether the token's `acr` and `auth_time` meet `requirement`: `:ok`,
  # or the refusal, with what was asked and the part not met. No token
  # (no authorization on the endpoint) means no gating.
  @spec authenticate(Sake.Auth.Authentication.requirement() | nil, Sake.Context.t()) ::
          :ok | {:insufficient_user_authentication, map()}
  def authenticate(nil, _ctx), do: :ok
  def authenticate(_requirement, %Sake.Context{token: nil}), do: :ok

  def authenticate(requirement, %Sake.Context{token: token}) do
    context = Sake.Auth.Authentication.context(Map.from_struct(token))

    case Sake.Auth.Authentication.check(context, requirement) do
      :ok ->
        :ok

      {:error, reason} ->
        {:insufficient_user_authentication,
         %{
           acr_values: requirement.acr_values,
           max_age: requirement.max_age,
           reason: reason,
           scopes: []
         }}
    end
  end

  @spec capabilities(module()) :: map()
  def capabilities(server) do
    tools = server.__sake__(:tools)
    resources = server.__sake__(:resources)
    prompts = server.__sake__(:prompts)
    proxied = proxied(server)
    skills = server.__sake__(:skills) != [] or proxied.skills

    %{"logging" => %{}}
    |> put_capability(tools != [] or proxied.tools, "tools", %{"listChanged" => true})
    |> put_capability(resources != [] or skills or proxied.resources, "resources", %{
      "listChanged" => true,
      "subscribe" => proxied.subscribe or Enum.any?(resources, & &1.subscribe)
    })
    |> put_capability(prompts != [] or proxied.prompts, "prompts", %{"listChanged" => true})
    |> put_capability(
      proxied.completions or Enum.any?(tools ++ resources ++ prompts, &completable?/1),
      "completions",
      %{}
    )
  end

  @doc false
  # Whether the server serves skills: its own, its mounted servers', or
  # a proxy's that passes its upstream's on.
  @spec skills?(module()) :: boolean()
  def skills?(server), do: server.__sake__(:skills) != [] or proxied(server).skills

  defp put_capability(caps, true, name, value), do: Map.put(caps, name, value)
  defp put_capability(caps, false, _name, _value), do: caps

  defp completable?(%{module: module}),
    do: Code.ensure_loaded?(module) and function_exported?(module, :complete, 3)

  # What the server's proxies may list. Their upstream is not asked: the
  # capabilities a client gets do not depend on who asks, nor on whether
  # an upstream is reachable at that moment.
  defp proxied(server) do
    none = %{
      tools: false,
      resources: false,
      prompts: false,
      skills: false,
      completions: false,
      subscribe: false
    }

    server.__sake__(:sources)
    |> Enum.map(fn {proxy, _chain} -> Sake.Proxy.exposes(proxy) end)
    |> Enum.reduce(none, &Map.merge(&2, &1, fn _key, a, b -> a or b end))
  end

  @doc false
  # The proxies' components of `kind` for the request, through the
  # mounts between them and the server, none whose key a static
  # component has taken.
  def proxied_components(server, kind, static, ctx) do
    case server.__sake__(:sources) do
      [] -> []
      sources -> server_authentication(server, dynamic(sources, kind, static, ctx))
    end
  end

  @doc false
  # The server's `authentication:` on a component known at runtime.
  def with_server_authentication(server, spec), do: hd(server_authentication(server, [spec]))

  @doc false
  # Whether the server lists components it learns at runtime, from a
  # proxy: its lists then differ between principals.
  @spec dynamic?(module()) :: boolean()
  def dynamic?(server), do: server.__sake__(:sources) != []

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
