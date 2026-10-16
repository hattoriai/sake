defmodule Sake.Proxy do
  @moduledoc """
  A server whose tools, resources and prompts are another MCP server's:
  every call is forwarded to that upstream with `Sake.Client`, and the
  proxy adds what the upstream lacks, your login and scopes, middleware
  (access control, audit, rate limits), on one approved endpoint.

      defmodule MyApp.MCP.GitHub do
        use Sake.Proxy,
          name: "github",
          version: "1.0.0",
          upstream: "https://api.githubcopilot.com/mcp/",
          tools: [except: ["delete_repository"]],
          scope: "github",
          scopes: %{"create_issue" => "github:write"}

        @impl Sake.Proxy
        def credentials(ctx) do
          case MyApp.Accounts.github_token(ctx.scope) do
            {:ok, token} -> {:bearer, token}
            :error -> {:error, "Connect your GitHub account first."}
          end
        end
      end

  A proxy is a `Sake.Server`: serve it on its own endpoint, or `mount`
  it in another server, under a prefix, next to local modules and other
  proxies (see `Sake.Server.mount/2`). It may also declare tools of its
  own and middleware, which runs around the proxied components as around
  any other. Add it to the supervision tree, after `Sake`; it keeps the
  upstream sessions:

      children = [
        {Sake, secret_key_base: ...},
        {MyApp.MCP.GitHub, upstream: System.fetch_env!("GITHUB_MCP_URL")}
      ]

  ## Options

  The `Sake.Server` options (`name:`, `version:` and the others), and:

    * `:upstream` (required) — the URL of a Streamable HTTP server, or
      `{:stdio, command, args}` for a server the proxy starts as a
      subprocess.
    * `:connect` — options for `Sake.Client.connect/2`: `era:`,
      `headers:` (a fixed token: `[{"authorization", "Bearer ..."}]`),
      `auth:` (the client's own authorization, such as a machine
      client's `client_credentials`), `req:`, and for stdio `env:`, `cd:`
      and `stderr:`.
    * `:tools` and `:prompts` — `true` (the default), `false`, or
      `[only: names]` / `[except: names]`, by the upstream's names.
    * `:resources` — `true` (the default) or `false`.
    * `:scope` — one or more scopes every proxied component requires.
    * `:scopes` — a map from an upstream tool or prompt name to the
      scopes it requires on top of `:scope`.
    * `:list_ttl` — how long, in ms, an upstream's lists are kept when it
      does not say (a legacy upstream); default 60 000. A modern
      upstream's own `ttlMs` is used when it gives one.
    * `:idle_timeout` — how long, in ms, an unused upstream session is
      kept; default 600 000.

  Each option may also be given at runtime, in the child spec, where it
  overrides the one given to `use`.

  ## Credentials

  Without `credentials/1`, the proxy calls the upstream with what
  `:connect` gives it: no credentials, a fixed token in `headers:`, or
  `Sake.Client`'s own authorization (`auth:`). With it, each request's
  principal acts as itself upstream: the callback gets the request's
  `Sake.Context` and returns `{:bearer, token}`, `{:headers, headers}`,
  `:none`, or `{:error, message}` to refuse (the lists leave the proxied
  components out, and a call gets `message`).

  Upstream sessions are kept per principal (the token's subject, else
  the host's scope) and per credential: one principal's session, token,
  tasks or requests are never used for another. A stdio upstream is one
  process for everyone (its credentials come from its environment, and
  `credentials/1` does not apply), and the proxy sends it one request at
  a time, since a stdio server cannot
  tell its callers' questions and log messages apart. A session the
  upstream refuses (a 401, an expired legacy session) is dropped and
  opened again once, with fresh credentials.

  ## What is forwarded

  See "Proxying another server" in `guides/composing.md` for the
  details: the lists (cached by the upstream's `ttlMs`), calls, reads,
  prompts and completions; progress and log messages; elicitation,
  sampling and roots requests, across eras; an upstream's tasks, which
  become the proxy's own; and, when every principal has the same
  upstream identity, the upstream's list changes and the updates of the
  resources clients subscribed to, broadcast as the proxy's.
  """

  alias Sake.Proxy.{Specs, Upstream}

  @typedoc "What `credentials/1` returns."
  @type credentials ::
          {:bearer, String.t()}
          | {:headers, [{String.t(), String.t()}]}
          | :none
          | {:error, String.t()}

  @doc """
  The credentials the request's principal calls the upstream with. See
  "Credentials" above.
  """
  @callback credentials(ctx :: Sake.Context.t()) :: credentials()
  @optional_callbacks credentials: 1

  @proxy_keys [
    :upstream,
    :connect,
    :tools,
    :prompts,
    :resources,
    :scope,
    :scopes,
    :list_ttl,
    :idle_timeout
  ]

  @doc false
  def proxy_keys, do: @proxy_keys

  defmacro __using__(opts) do
    {proxy, server} = Keyword.split(opts, @proxy_keys)

    quote do
      use Sake.Server, unquote(server)
      @behaviour Sake.Proxy
      @sake_proxy true

      @doc false
      def __sake_proxy__, do: unquote(proxy)

      @doc "The child that keeps this proxy's upstream sessions; see `Sake.Proxy`."
      def child_spec(opts), do: Sake.Proxy.child_spec(__MODULE__, opts)
    end
  end

  @doc false
  def child_spec(proxy, opts) do
    %{
      id: proxy,
      start: {Upstream, :start_link, [proxy, Keyword.merge(proxy.__sake_proxy__(), opts)]}
    }
  end

  @doc false
  # The upstream's components of `kind` the request may see, as the proxy
  # lists them (not yet under any mount's prefix); none when the upstream
  # cannot be reached or the principal has no credentials for it.
  @spec components(module(), :tools | :resources | :prompts, Sake.Context.t()) :: [struct()]
  def components(proxy, kind, ctx) do
    case Upstream.list(proxy, kind, ctx) do
      {:ok, specs, ttl} -> Enum.map(specs, &current(&1, ttl, proxy))
      :error -> []
    end
  end

  # A component is listed for what is left of its list's ttl, and a
  # resource takes subscriptions while the proxy follows its upstream.
  defp current(%Sake.Resource.Spec{} = spec, ttl, proxy),
    do: %{spec | ttl: ttl, subscribe: Sake.Proxy.Watcher.subscribe?(proxy)}

  defp current(spec, ttl, _proxy), do: %{spec | ttl: ttl}

  @doc false
  # The resource the upstream serves at `uri`: one it lists, one of its
  # templates, or, when the proxy is to `claim?` the URI, any other.
  @spec resource(module(), String.t(), Sake.Context.t(), boolean()) ::
          {:ok, Sake.Resource.Spec.t()} | :error
  def resource(proxy, uri, ctx, claim?) do
    resources = components(proxy, :resources, ctx)

    cond do
      not exposes(proxy).resources ->
        :error

      spec = Enum.find(resources, &match?({:ok, _}, Sake.Resource.Spec.match(&1, uri))) ->
        {:ok, spec}

      claim? ->
        {:ok, Specs.unlisted(proxy, uri, Upstream.config(proxy))}

      true ->
        :error
    end
  end

  @doc false
  # Whether the upstream lists a resource at `uri`, or has a template for
  # it: a URI in a proxied result is renamed under a mount's prefix only
  # then (see `Sake.Server.Mount.outer_result/3`).
  @spec serves?(module(), String.t(), Sake.Context.t()) :: boolean()
  def serves?(proxy, uri, ctx) do
    proxy
    |> components(:resources, ctx)
    |> Enum.any?(&match?({:ok, _}, Sake.Resource.Spec.match(&1, uri)))
  end

  @doc false
  # What the proxy may list, for the server's capabilities.
  @spec exposes(module()) :: %{atom() => boolean()}
  def exposes(proxy) do
    config = Upstream.config(proxy)
    tools = config[:tools] != false
    resources = config[:resources] != false
    prompts = config[:prompts] != false

    %{
      tools: tools,
      resources: resources,
      prompts: prompts,
      completions: resources or prompts,
      subscribe: resources and Sake.Proxy.Watcher.subscribe?(proxy)
    }
  end

  @doc false
  # A client subscribed to a proxied resource: the proxy's watcher follows
  # it upstream, when it can.
  @spec follow(struct(), String.t()) :: :ok
  def follow(%{proxy: proxy} = spec, uri) do
    with true <- Sake.Proxy.Watcher.subscribe?(proxy),
         {:ok, inner} <- Sake.Server.Mount.inner_uri(spec, uri),
         do: Upstream.follow(proxy, inner)

    :ok
  end
end
