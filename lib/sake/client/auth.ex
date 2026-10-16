defmodule Sake.Client.Auth do
  @moduledoc """
  The MCP authorization flow, run by `Sake.Client` itself. Turn it on with
  `auth:` on `Sake.Client.connect/2`:

      {:ok, session} =
        Sake.Client.connect("https://mcp.example.com/mcp",
          auth: [authorize: &Sake.Client.Auth.Browser.authorize/1]
        )

  On a 401 the client discovers the authorization server (RFC 9728, then
  RFC 8414 or OpenID Connect Discovery), registers or identifies itself,
  sends the person to the authorization endpoint (PKCE with S256, a
  `state`, the RFC 8707 `resource`), checks the answer (`state`, and the
  RFC 9207 `iss`), exchanges the code for a token, and retries the
  request with it. From then on every request carries the token; an
  expired one is refreshed, a 401 tries the refresh token before the whole
  flow, and a 403 `insufficient_scope` asks again for the union of the
  scopes requested so far and the challenged ones (step-up), at most
  twice for one request.

  Options:

    * `:authorize` — the interactive step: a function that receives the
      authorization URL and returns `{:ok, params}`, the query parameters
      the authorization server sent to the redirect URI (`"code"`,
      `"state"`, `"iss"`, or `"error"`), or `{:error, reason}`. Default
      `Sake.Client.Auth.Browser.authorize/1`; `Sake.Client.Auth.Headless.authorize/1`
      is the one for an authorization server that approves without a
      person.
    * `:redirect_uri` — where the authorization server sends the answer.
      Default `"http://127.0.0.1:33418/callback"`, a loopback address
      `Sake.Client.Auth.Browser` listens on.
    * `:client_id`, `:client_secret` — pre-registered credentials, used
      before anything else. `:issuer` names the authorization server they
      belong to; without it they are bound to the first one they are used
      with, and never offered to another. `:token_endpoint_auth_method`
      overrides the method chosen from the server's metadata.
    * `:client_metadata_url` — the HTTPS URL of the client's own Client ID
      Metadata Document, used as the `client_id` when the authorization
      server supports them. Its `redirect_uris` must include
      `:redirect_uri`.
    * `:client_name` — the name a dynamic registration (RFC 7591) gives;
      default the `client_info` name.
    * `:store` — `{module, arg}`, a `Sake.Client.Auth.Store` that keeps
      tokens and dynamic registrations across sessions. Without one, they
      live in the session only.

  Machine grants, for a client with no person at a browser, run in place
  of the authorization code flow, with the same discovery and the same
  handling of expiry, 401 and step-up (the grant runs again, with the
  union of the scopes, where a person would have been asked):

    * `grant: :client_credentials` — the client acts as itself (the
      `io.modelcontextprotocol/oauth-client-credentials` extension). It
      needs `:client_id` and either `:client_secret` or `:private_key`.
    * `grant: :jwt_bearer` — the client presents a JWT it was given as
      the grant (RFC 7523 §2.1), a workload identity token from its
      platform, say. `:assertion` is the JWT, or a function of
      `%{issuer: issuer, resource: resource}` returning
      `{:ok, jwt}` (to ask the platform for one with the right
      audience). `:client_id` is optional.
    * `grant: :enterprise` — enterprise-managed authorization
      (`io.modelcontextprotocol/enterprise-managed-authorization`): the
      person's ID token from the host's single sign-on is exchanged at
      the enterprise identity provider for an ID-JAG (RFC 8693), which
      the MCP authorization server takes as a JWT bearer grant. It needs
      `:client_id` (and `:client_secret` or `:private_key` when the client
      is confidential there), `:id_token` (the ID token, or a function
      like `:assertion`'s), and `:idp`: `token_endpoint:` or `issuer:` (to
      read it from the provider's metadata), and the client's
      `client_id:` and `client_secret:` at the provider.

  DPoP (RFC 9449) binds the tokens to a key the client holds, so a token
  that leaks is useless without it:

    * `:dpop` — `:auto` (the default) uses DPoP with an authorization
      server whose metadata lists ES256 in
      `dpop_signing_alg_values_supported`; `true` sends proofs to any
      server; `false` never does. It needs the optional `jose`
      dependency: without it, `:auto` never uses DPoP, and `true` raises.

  With DPoP, each authorization makes a new P-256 key, kept with the
  token (as PEM, in the `:store` too: a bound token is useless without
  it). Every token request carries a proof made with it, and every
  request to the MCP server sends the token with the `DPoP` scheme and a
  fresh proof bound to it. A server that asks for a nonce
  (`use_dpop_nonce`) gets the request again with its nonce, which the
  client then keeps sending; that retry does not count as an
  authorization.

  `:private_key` is a PEM private key, or `{pem, alg}` to sign with
  another algorithm than its default (RS256 for RSA, ES256 for P-256):
  the client then authenticates with `private_key_jwt` (RFC 7523 §2.2),
  signing a short-lived assertion for every token request. It needs the
  optional `jose` dependency. Machine grants get no refresh token: an
  expired token is replaced by running the grant again.

  Without `auth:`, a 401 is returned as
  `{:error, {:unauthorized, %Sake.Client.Challenge{}}}` and the caller
  handles it. A failure inside the flow is `{:error, {:auth, reason}}`.
  """

  alias Sake.Auth.{DPoP, JWT}
  alias Sake.Client.Auth.{Browser, Discovery, Enterprise, Grant, Registration}
  alias Sake.Client.Challenge

  @type t :: %__MODULE__{}

  @redirect_uri "http://127.0.0.1:33418/callback"

  # A token this close to its expiry is refreshed before it is sent, so it
  # does not expire on the way.
  @expiry_margin 30

  @grants [:authorization_code, :client_credentials, :jwt_bearer, :enterprise]

  defstruct [
    :url,
    :authorize,
    :private_key,
    :assertion,
    :id_token,
    :idp,
    :redirect_uri,
    :client_id,
    :client_secret,
    :token_endpoint_auth_method,
    :client_issuer,
    :client_metadata_url,
    :client_name,
    :store,
    :token,
    :proof_key,
    grant: :authorization_code,
    dpop: :auto,
    clients: %{},
    nonces: %{},
    req: []
  ]

  @doc false
  @spec new(String.t(), keyword(), keyword()) :: t()
  def new(url, opts, defaults) do
    authorize = opts[:authorize] || (&Browser.authorize/1)

    unless is_function(authorize, 1),
      do: raise(ArgumentError, "auth: :authorize must be a function of one argument")

    auth = %__MODULE__{
      url: Discovery.canonical(url),
      grant: grant(opts),
      authorize: authorize,
      redirect_uri: opts[:redirect_uri] || @redirect_uri,
      client_id: opts[:client_id],
      client_secret: opts[:client_secret],
      private_key: private_key(opts[:private_key]),
      assertion: opts[:assertion],
      id_token: opts[:id_token],
      idp: idp(opts[:idp]),
      token_endpoint_auth_method: opts[:token_endpoint_auth_method],
      client_issuer: opts[:issuer],
      client_metadata_url: metadata_url(opts[:client_metadata_url]),
      client_name: opts[:client_name] || defaults[:client_name] || "Sake",
      store: opts[:store],
      dpop: dpop(Keyword.get(opts, :dpop, :auto)),
      req: defaults[:req] || []
    }

    check_grant!(auth)
    token = fetch(auth, {:token, auth.url})
    %{auth | token: token, proof_key: proof_key(token)}
  end

  defp dpop(:auto), do: :auto
  defp dpop(false), do: false

  defp dpop(true) do
    JWT.require!("auth: [dpop: true]")
    true
  end

  defp dpop(other),
    do: raise(ArgumentError, "auth: :dpop must be :auto, true or false, got #{inspect(other)}")

  defp grant(opts) do
    grant = Keyword.get(opts, :grant, :authorization_code)

    if grant in @grants,
      do: grant,
      else: raise(ArgumentError, "auth: :grant must be one of #{inspect(@grants)}")
  end

  defp private_key(nil), do: nil
  defp private_key(pem) when is_binary(pem), do: private_key({pem, nil})

  defp private_key({pem, alg}) do
    JWT.require!("auth: :private_key")

    case JWT.private_key(pem) do
      {:ok, key} when alg == nil ->
        {key, JWT.default_alg(key)}

      {:ok, key} ->
        if alg in JWT.algs(),
          do: {key, alg},
          else:
            raise(
              ArgumentError,
              "auth: :private_key's algorithm must be one of #{inspect(JWT.algs())}"
            )

      {:error, :invalid_key} ->
        raise ArgumentError,
              "auth: :private_key must be a PEM RSA (2048 bits or more), P-256 or P-384 private key"
    end
  end

  defp idp(nil), do: nil
  defp idp(opts) when is_list(opts), do: Map.new(opts)
  defp idp(%{} = opts), do: opts

  defp check_grant!(%__MODULE__{grant: :client_credentials} = auth) do
    unless is_binary(auth.client_id) and
             (is_binary(auth.client_secret) or auth.private_key != nil),
           do:
             raise(
               ArgumentError,
               "grant: :client_credentials needs :client_id and :client_secret or :private_key"
             )
  end

  defp check_grant!(%__MODULE__{grant: :jwt_bearer} = auth) do
    unless provided?(auth.assertion),
      do: raise(ArgumentError, "grant: :jwt_bearer needs :assertion (a JWT or a function)")
  end

  defp check_grant!(%__MODULE__{grant: :enterprise} = auth) do
    cond do
      not is_binary(auth.client_id) ->
        raise ArgumentError, "grant: :enterprise needs :client_id"

      not provided?(auth.id_token) ->
        raise ArgumentError, "grant: :enterprise needs :id_token (an ID token or a function)"

      not (is_map(auth.idp) and
               (is_binary(auth.idp[:token_endpoint]) or is_binary(auth.idp[:issuer]))) ->
        raise ArgumentError,
              "grant: :enterprise needs idp: [token_endpoint: url] or idp: [issuer: url]"

      true ->
        :ok
    end
  end

  defp check_grant!(_auth), do: :ok

  defp provided?(value), do: is_binary(value) or is_function(value, 1)

  # draft-ietf-oauth-client-id-metadata-document: an https URL with a path.
  defp metadata_url(nil), do: nil

  defp metadata_url(url) do
    if Sake.Auth.CIMD.url?(url),
      do: url,
      else: raise(ArgumentError, "auth: :client_metadata_url must be an https URL with a path")
  end

  @doc false
  # The headers of one request to the MCP server, `method` to `url`: the
  # token, and with a DPoP-bound one a proof for this request, bound to
  # the token and with the server's latest nonce. A bound token whose key
  # is gone (a store that lost it) goes as a bearer token, which the
  # server refuses: the 401 runs the flow again, for a new token and key.
  @spec headers(t() | nil, String.t(), String.t(), [{String.t(), String.t()}]) ::
          [{String.t(), String.t()}]
  def headers(%__MODULE__{token: %{"access_token" => token}} = auth, method, url, headers) do
    case bound_key(auth) do
      nil ->
        [{"authorization", "Bearer " <> token} | without(headers, [])]

      key ->
        proof =
          DPoP.proof(key, method, url, access_token: token, nonce: auth.nonces[origin(url)])

        [{"authorization", "DPoP " <> token}, {"dpop", proof} | without(headers, ["dpop"])]
    end
  end

  def headers(_auth, _method, _url, headers), do: headers

  defp without(headers, names) do
    names = ["authorization" | names]
    Enum.reject(headers, fn {name, _} -> String.downcase(name) in names end)
  end

  @doc false
  # The server's latest DPoP nonce (RFC 9449 §8 and §9), from a challenge
  # or a `DPoP-Nonce` header, kept per origin.
  @spec put_nonce(t() | nil, String.t(), String.t() | nil) :: t() | nil
  def put_nonce(%__MODULE__{} = auth, url, nonce) when is_binary(nonce),
    do: %{auth | nonces: Map.put(auth.nonces, origin(url), nonce)}

  def put_nonce(auth, _url, _nonce), do: auth

  defp origin(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end

  # ---- what Sake.Client calls

  @doc false
  @spec fresh(t()) :: t()
  def fresh(%__MODULE__{token: %{"expires_at" => at, "refresh_token" => r} = token} = auth)
      when is_integer(at) and is_binary(r) do
    if System.system_time(:second) < at - @expiry_margin do
      auth
    else
      case refresh(auth, token, token["token_endpoint"]) do
        {:ok, auth} -> auth
        {:error, auth} -> auth
      end
    end
  end

  # A machine grant has no refresh token: an expiring token is replaced by
  # running the grant again, against the authorization server it came
  # from.
  def fresh(%__MODULE__{grant: grant, token: %{"expires_at" => at} = token} = auth)
      when grant != :authorization_code and is_integer(at) do
    if System.system_time(:second) < at - @expiry_margin do
      auth
    else
      case renew(auth, token) do
        {:ok, auth} -> auth
        {:error, _reason, auth} -> auth
      end
    end
  end

  def fresh(auth), do: auth

  @doc false
  @spec unauthorized(t(), Challenge.t(), boolean()) :: {:ok, t()} | {:error, term(), t()}
  def unauthorized(auth, challenge, refresh?) do
    case discover(auth, challenge) do
      {:ok, server} ->
        case maybe_refresh(auth, server, refresh?) do
          {:ok, auth} -> {:ok, auth}
          {:error, auth} -> authorize(auth, server, scopes(auth, server, challenge))
        end

      {:error, reason} ->
        {:error, reason, auth}
    end
  end

  @doc false
  @spec insufficient_scope(t(), Challenge.t()) :: {:ok, t()} | {:error, term(), t()} | :exhausted
  def insufficient_scope(auth, %Challenge{scope: challenged} = challenge) do
    # Asking again for scopes the token already has would only end in the
    # same 403: the server wants something the authorization server will
    # not grant, and that is the caller's answer.
    if challenged -- granted(auth.token) == [] do
      :exhausted
    else
      case discover(auth, challenge) do
        {:ok, server} ->
          authorize(auth, server, union(requested(auth.token), challenged, server.metadata))

        {:error, reason} ->
          {:error, reason, auth}
      end
    end
  end

  defp discover(auth, challenge) do
    Discovery.discover(
      auth.url,
      challenge,
      auth.client_issuer,
      auth.req,
      auth.grant == :authorization_code
    )
  end

  # ---- scopes

  # The scopes of a first authorization, by the specification's rule: the
  # challenge's `scope` when it has one, else every scope in the resource
  # metadata's `scopes_supported`, else none (the `scope` parameter is
  # omitted).
  @doc false
  @spec select_scopes(Challenge.t() | nil, map()) :: [String.t()]
  def select_scopes(%Challenge{scope: [_ | _] = scopes}, _server), do: scopes
  def select_scopes(_challenge, %{scopes_supported: [_ | _] = scopes}), do: scopes
  def select_scopes(_challenge, _server), do: []

  # Re-authorizing for the same resource keeps the scopes asked for before,
  # so a new token does not lose what the old one could do.
  defp scopes(auth, server, challenge) do
    previous =
      if auth.token && auth.token["resource"] == server.resource,
        do: requested(auth.token),
        else: []

    union(previous, select_scopes(challenge, server), server.metadata)
  end

  # `offline_access` asks for a refresh token (SEP-2207), and only from a
  # server that lists it; it is added to a non-empty request only, since
  # on its own it would replace the server's default scopes.
  @doc false
  @spec union([String.t()], [String.t()], map()) :: [String.t()]
  def union(previous, scopes, metadata) do
    scopes = Enum.uniq((previous -- ["offline_access"]) ++ scopes)

    if scopes != [] and "offline_access" in List.wrap(metadata["scopes_supported"]),
      do: scopes ++ ["offline_access"],
      else: scopes
  end

  defp granted(%{"scopes" => scopes}), do: scopes
  defp granted(_token), do: []

  defp requested(%{"requested_scopes" => scopes}), do: scopes
  defp requested(_token), do: []

  # ---- the flow

  defp authorize(%__MODULE__{grant: :authorization_code} = auth, server, scopes),
    do: authorize_code(auth, server, scopes)

  # `offline_access` asks for a refresh token, which no machine grant gets.
  defp authorize(auth, server, scopes) do
    scopes = scopes -- ["offline_access"]

    case machine_client(auth, server) do
      {:ok, registration, auth} ->
        machine(auth, server, registration, scopes, new_key(auth, server))

      {:error, reason, auth} ->
        {:error, reason, auth}
    end
  end

  defp authorize_code(auth, server, scopes) do
    case Registration.client(auth, server) do
      {:ok, registration, auth} ->
        {url, request} = Grant.request(server, registration, auth.redirect_uri, scopes)
        pem = new_key(auth, server)

        with {:ok, params} <- interact(auth.authorize, url),
             {:ok, code} <- Grant.callback(params, request),
             {:ok, body} <-
               Grant.exchange(
                 server,
                 registration,
                 request,
                 code,
                 auth.req,
                 proofs(auth, pem, server.metadata["token_endpoint"])
               ) do
          {:ok, put(auth, {:token, auth.url}, token(body, server, registration, scopes, pem))}
        else
          {:error, reason} -> {:error, reason, auth}
        end

      {:error, reason, auth} ->
        {:error, reason, auth}
    end
  end

  # A JWT bearer grant needs no client identity at all (RFC 7523 §3.1);
  # every other machine grant presents the pre-registered one.
  defp machine_client(%__MODULE__{grant: :jwt_bearer, client_id: nil} = auth, server),
    do:
      {:ok,
       %{"client_id" => nil, "token_endpoint_auth_method" => "none", "issuer" => server.issuer},
       auth}

  defp machine_client(auth, server), do: Registration.client(auth, server)

  defp machine(auth, server, registration, scopes, pem) do
    dpop = proofs(auth, pem, server.metadata["token_endpoint"])

    case machine_token(auth, server, registration, scopes, dpop) do
      {:ok, body} ->
        {:ok, put(auth, {:token, auth.url}, token(body, server, registration, scopes, pem))}

      {:error, reason} ->
        {:error, reason, auth}
    end
  end

  defp machine_token(
         %__MODULE__{grant: :client_credentials} = auth,
         server,
         registration,
         scopes,
         dpop
       ),
       do: Grant.client_credentials(server, registration, scopes, auth.req, dpop)

  defp machine_token(%__MODULE__{grant: :jwt_bearer} = auth, server, registration, scopes, dpop) do
    with {:ok, jwt} <- provide(auth.assertion, server),
         do: Grant.jwt_bearer(server, registration, jwt, scopes, auth.req, dpop)
  end

  # The token exchange at the identity provider carries no proof: the
  # ID-JAG it returns is not presented to anyone but the authorization
  # server, whose own token is the one bound.
  defp machine_token(%__MODULE__{grant: :enterprise} = auth, server, registration, scopes, dpop) do
    with {:ok, id_token} <- provide(auth.id_token, server),
         {:ok, jag} <- Enterprise.exchange(auth.idp, id_token, server, scopes, auth.req),
         do: Grant.jwt_bearer(server, registration, jag, scopes, auth.req, dpop)
  end

  defp provide(value, _server) when is_binary(value), do: {:ok, value}

  defp provide(fun, server) do
    case fun.(%{issuer: server.issuer, resource: server.resource}) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      value when is_binary(value) -> {:ok, value}
      {:error, reason} -> {:error, {:assertion, reason}}
      other -> {:error, {:assertion, other}}
    end
  end

  # The token remembers its authorization server, its token endpoint, the
  # client it was issued to and its DPoP key: enough to run a machine
  # grant again without discovering anything.
  defp renew(auth, token) do
    server = %{
      issuer: token["issuer"],
      resource: token["resource"],
      metadata: %{"token_endpoint" => token["token_endpoint"]}
    }

    case Registration.for_token(auth, token) do
      %{} = registration ->
        machine(auth, server, registration, requested(token), token["dpop_key"])

      nil ->
        {:error, :no_client, auth}
    end
  end

  defp interact(authorize, url) do
    case authorize.(url) do
      {:ok, params} when is_map(params) -> {:ok, params}
      {:error, reason} -> {:error, {:authorize, reason}}
      other -> {:error, {:authorize, other}}
    end
  end

  # The refresh token is only used with the authorization server and for
  # the resource it was issued for; after a move to another server the
  # whole flow runs against the new one.
  defp maybe_refresh(%__MODULE__{token: %{"refresh_token" => r} = token} = auth, server, true)
       when is_binary(r) do
    if token["issuer"] == server.issuer and token["resource"] == server.resource,
      do: refresh(auth, token, server.metadata["token_endpoint"]),
      else: {:error, auth}
  end

  defp maybe_refresh(auth, _server, _refresh?), do: {:error, auth}

  # A refresh token that failed once is dropped: the next 401 runs the
  # whole flow instead of trying it again. A refresh keeps the token's
  # DPoP key: the authorization server binds a public client's refresh
  # token to it.
  defp refresh(auth, token, endpoint) do
    with %{} = registration <- Registration.for_token(auth, token),
         {:ok, body} <-
           Grant.refresh(
             endpoint,
             registration,
             token["refresh_token"],
             token["resource"],
             auth.req,
             proofs(auth, token["dpop_key"], endpoint)
           ) do
      {:ok, put(auth, {:token, auth.url}, refreshed(body, token))}
    else
      _ -> {:error, put(auth, {:token, auth.url}, Map.delete(token, "refresh_token"))}
    end
  end

  # ---- DPoP keys

  # A new authorization gets a new key, when the client uses DPoP with
  # this server at all.
  defp new_key(%__MODULE__{dpop: false}, _server), do: nil

  defp new_key(auth, server) do
    cond do
      not DPoP.available?() ->
        nil

      auth.dpop == true ->
        DPoP.generate_key()

      "ES256" in List.wrap(server.metadata["dpop_signing_alg_values_supported"]) ->
        DPoP.generate_key()

      true ->
        nil
    end
  end

  defp proofs(auth, pem, endpoint) do
    case key(auth, pem) do
      nil -> nil
      key -> %{key: key, nonce: auth.nonces[origin(endpoint)]}
    end
  end

  # The key a token is sent with: a DPoP-bound token's own.
  defp bound_key(%__MODULE__{token: %{"token_type" => "DPoP", "dpop_key" => pem}} = auth),
    do: key(auth, pem)

  defp bound_key(_auth), do: nil

  # A key from its PEM, read once per token and kept in the session.
  defp key(%__MODULE__{proof_key: {pem, key}}, pem), do: key

  defp key(_auth, pem) do
    case proof_key(%{"dpop_key" => pem}) do
      {_pem, key} -> key
      nil -> nil
    end
  end

  defp proof_key(%{"dpop_key" => pem}) when is_binary(pem) do
    case JWT.private_key(pem) do
      {:ok, key} -> {pem, key}
      {:error, :invalid_key} -> nil
    end
  end

  defp proof_key(_token), do: nil

  defp token(body, server, registration, requested, pem) do
    %{
      "access_token" => body["access_token"],
      "token_type" => token_type(body),
      "dpop_key" => pem,
      "refresh_token" => body["refresh_token"],
      "expires_at" => expires_at(body["expires_in"]),
      "scopes" => scope(body["scope"]) || requested,
      "requested_scopes" => requested,
      "issuer" => server.issuer,
      "token_endpoint" => server.metadata["token_endpoint"],
      "resource" => server.resource,
      "client_id" => registration["client_id"],
      "token_endpoint_auth_method" => registration["token_endpoint_auth_method"]
    }
  end

  # RFC 6749 §6: a refresh answer without a new refresh token leaves the
  # old one valid, and one without `scope` keeps the scopes as they were.
  defp refreshed(body, token) do
    Map.merge(token, %{
      "access_token" => body["access_token"],
      "token_type" => token_type(body),
      "refresh_token" => body["refresh_token"] || token["refresh_token"],
      "expires_at" => expires_at(body["expires_in"]),
      "scopes" => scope(body["scope"]) || token["scopes"]
    })
  end

  # The scheme the token is sent with: what the token endpoint says it is
  # (`Grant` accepts `DPoP` only in answer to a proof).
  defp token_type(%{"token_type" => type}) when is_binary(type) do
    if String.downcase(type) == "dpop", do: "DPoP", else: "Bearer"
  end

  defp expires_at(seconds) when is_integer(seconds), do: System.system_time(:second) + seconds

  defp expires_at(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {n, ""} -> expires_at(n)
      _ -> nil
    end
  end

  defp expires_at(_seconds), do: nil

  defp scope(scope) when is_binary(scope), do: String.split(scope)
  defp scope(_scope), do: nil

  # ---- state: in the session, and in the store when there is one

  @doc false
  @spec fetch(t(), Sake.Client.Auth.Store.key()) :: map() | nil
  def fetch(%__MODULE__{clients: clients} = auth, {:client, issuer} = key),
    do: clients[issuer] || stored(auth, key)

  def fetch(auth, key), do: stored(auth, key)

  defp stored(%__MODULE__{store: {module, arg}}, key) do
    case module.fetch(arg, key) do
      {:ok, value} when is_map(value) -> value
      _ -> nil
    end
  end

  defp stored(_auth, _key), do: nil

  @doc false
  @spec put(t(), Sake.Client.Auth.Store.key(), map()) :: t()
  def put(auth, {:client, issuer} = key, value) do
    persist(auth, key, value)
    %{auth | clients: Map.put(auth.clients, issuer, value)}
  end

  def put(auth, {:token, _url} = key, value) do
    persist(auth, key, value)
    %{auth | token: value, proof_key: proof_key(value)}
  end

  defp persist(%__MODULE__{store: {module, arg}}, key, value),
    do: :ok = module.put(arg, key, value)

  defp persist(_auth, _key, _value), do: :ok
end
