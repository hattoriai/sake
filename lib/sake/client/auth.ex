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
    * `:static` — `true` sends the token the `:store` holds as it is,
      for a token issued some other way (a test's, say): it is never
      refreshed, and a 401 or a 403 comes back to the caller instead of
      running the flow. Default `false`.

  A person without a browser on the client's machine (a CLI over SSH, a
  headless agent, a device) authorizes with the device authorization
  grant (RFC 8628) in place of the code flow:

    * `grant: :device` — the client asks the authorization server's
      `device_authorization_endpoint` for a user code, shows it with
      `:device_prompt` (default `Sake.Client.Auth.Device.prompt/1`,
      which logs it; see there), and polls the token endpoint while the
      person enters the code and approves on any device where they can
      sign in. Polling honours the server's `interval`, and `slow_down`
      adds five seconds to it (RFC 8628 §3.5); a denial or an expiry
      ends it with `{:error, {:auth, :access_denied}}` or
      `{:error, {:auth, :expired_token}}`. A server whose metadata has
      no device endpoint ends it with `{:error, {:auth,
      :no_device_endpoint}}`. The tokens are refreshed as the code
      flow's are; a step-up, or a 401 the refresh token does not cure,
      runs the device flow again.

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
      `client_id:` and `client_secret:` at the provider
      (`token_endpoint_auth_method:` overrides the method its metadata
      suggests, `"client_secret_jwt"` included, and
      `assertion_audience:` is as below, for the provider).

      With SAML single sign-on, `:saml_assertion` (the base64url-encoded
      assertion, or a function like `:assertion`'s) replaces `:id_token`,
      and `:idp` needs `issuer:`; `idp: [saml_scope: [...]]` is the
      `scope` of the SAML exchange alone (none by default; some
      providers want `"offline_access"` before they issue a refresh
      token). The assertion is first exchanged at the
      provider for a refresh token, which is then exchanged for the
      ID-JAG (draft-ietf-oauth-identity-assertion-authz-grant §4.5). The
      refresh token is kept, in the session and the `:store`, and used for
      the next ID-JAGs until it expires or the provider refuses it; only
      then is an assertion asked for again.

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
  fresh proof bound to it. A resource whose metadata says
  `dpop_bound_access_tokens_required` gets DPoP with `:auto` whatever the
  authorization server's metadata lists; when the client cannot use it
  (`dpop: false`, or no `jose`), the flow stops at once with
  `{:dpop_required, :dpop_off | :no_jose}`. A server that asks for a nonce
  (`use_dpop_nonce`) gets the request again with its nonce, which the
  client then keeps sending; that retry does not count as an
  authorization.

  `:private_key` is a PEM private key, or `{pem, alg}` to sign with
  another algorithm than its default (RS256 for RSA, ES256 for P-256):
  the client then authenticates with `private_key_jwt` (RFC 7523 §2.2),
  signing a short-lived assertion for every token request. It needs the
  optional `jose` dependency. `token_endpoint_auth_method:
  "client_secret_jwt"` signs the same assertion with HS256 over
  `:client_secret` instead (at least 32 bytes), which needs no `jose`;
  it is also chosen for a server that lists it as its only secret
  method. `:assertion_audience` sets the `aud` of both kinds of client
  assertion: `:issuer` (the default, the server's issuer identifier, as
  draft-ietf-oauth-rfc7523bis asks), `:token_endpoint` (the token
  endpoint's URL, which some servers want), or a string to send as it
  is. Machine grants get no refresh token: an
  expired token is replaced by running the grant again.

  Pushed authorization requests (RFC 9126) keep the authorization
  request out of the browser:

    * `:par` — `:auto` (the default) pushes the request to the server's
      `pushed_authorization_request_endpoint` whenever its metadata
      lists one, authenticated as at the token endpoint and with a DPoP
      proof when the client uses DPoP (the code is then bound to the
      key), and opens the authorization endpoint with only the
      `client_id` and the `request_uri` it got back. `false` sends the
      request through the browser, unless the metadata says
      `require_pushed_authorization_requests`: such a server gets it
      pushed anyway. A push the server refuses ends the flow with
      `{:error, {:auth, {:par_failed, status, body}}}`.

  Without `auth:`, a 401 is returned as
  `{:error, {:unauthorized, %Sake.Auth.Challenge{}}}` and the caller
  handles it. A failure inside the flow is `{:error, {:auth, reason}}`.
  """

  alias Sake.Auth.{Challenge, DPoP, JWT}
  alias Sake.Client.Auth.{Browser, Device, Discovery, Enterprise, Grant, Registration}

  @type t :: %__MODULE__{}

  @redirect_uri "http://127.0.0.1:33418/callback"

  # A token this close to its expiry is refreshed before it is sent, so it
  # does not expire on the way.
  @expiry_margin 30

  @grants [:authorization_code, :device, :client_credentials, :jwt_bearer, :enterprise]

  # RFC 8628 §3.5: `slow_down` makes every later poll this much later.
  @slow_down 5

  # ---- the interface
  #
  # What `Sake.Client` calls (and `Sake.Client.Transport`, for the
  # headers and the nonces), and all it calls; each is `@doc false`,
  # since only the options above are for host code:
  #
  #   * `new/3` — the state, from the `auth:` options, when the client
  #     connects (the client keeps nil without them, which the next four
  #     take as well, and do nothing with).
  #   * `extensions/1` — the authorization extensions the client
  #     declares in its capabilities, as atoms.
  #   * `headers/4` — a request's headers with the token, and a DPoP
  #     proof for it.
  #   * `put_nonce/3` — keeps a server's DPoP nonce, from a challenge or
  #     a `DPoP-Nonce` header.
  #   * `fresh/1` — before a request: the token refreshed, or the grant
  #     run again, when it is about to expire.
  #   * `unauthorized/3` — on a 401 challenge: the refresh token, else
  #     the flow; `:exhausted` with `:static`.
  #   * `insufficient_scope/2` — on a 403 challenge: the flow again for
  #     more scopes (step-up); `:exhausted` when it would not help.
  #
  # The challenges are `Sake.Auth.Challenge`s, parsed by the transport.

  defstruct [
    :url,
    :authorize,
    :private_key,
    :assertion,
    :id_token,
    :saml_assertion,
    :idp,
    :redirect_uri,
    :client_id,
    :client_secret,
    :token_endpoint_auth_method,
    :assertion_audience,
    :client_issuer,
    :client_metadata_url,
    :client_name,
    :store,
    :token,
    :static,
    :proof_key,
    :idp_token,
    :device_prompt,
    # How the device flow waits between polls, in milliseconds: a test's
    # stand-in for `Process.sleep/1`.
    :sleep,
    grant: :authorization_code,
    dpop: :auto,
    par: :auto,
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
      device_prompt: device_prompt(opts[:device_prompt]),
      sleep: opts[:sleep] || (&Process.sleep/1),
      redirect_uri: opts[:redirect_uri] || @redirect_uri,
      client_id: opts[:client_id],
      client_secret: opts[:client_secret],
      private_key: private_key(opts[:private_key]),
      assertion: opts[:assertion],
      id_token: opts[:id_token],
      saml_assertion: opts[:saml_assertion],
      idp: idp(opts[:idp]),
      token_endpoint_auth_method: opts[:token_endpoint_auth_method],
      assertion_audience: assertion_audience!(opts[:assertion_audience], "auth:"),
      client_issuer: opts[:issuer],
      client_metadata_url: metadata_url(opts[:client_metadata_url]),
      client_name: opts[:client_name] || defaults[:client_name] || "Sake",
      store: opts[:store],
      dpop: dpop(Keyword.get(opts, :dpop, :auto)),
      par: par(Keyword.get(opts, :par, :auto)),
      req: defaults[:req] || [],
      static: opts[:static] == true
    }

    check_grant!(auth)
    check_secret_jwt!(auth.token_endpoint_auth_method, auth.client_secret, "auth:")
    token = fetch(auth, {:token, auth.url})
    %{auth | token: token, proof_key: proof_key(token)}
  end

  @doc false
  # The authorization extension the grant belongs to, for the client's
  # capabilities (`Sake.Client` calls it). A workload's JWT grant and DPoP
  # define none: they are negotiated in the OAuth metadata alone.
  @spec extensions(t() | nil) :: [:client_credentials | :enterprise]
  def extensions(%__MODULE__{grant: grant}) when grant in [:client_credentials, :enterprise],
    do: [grant]

  def extensions(_auth), do: []

  defp device_prompt(nil), do: &Device.prompt/1
  defp device_prompt(prompt) when is_function(prompt, 1), do: prompt

  defp device_prompt(_prompt),
    do: raise(ArgumentError, "auth: :device_prompt must be a function of one argument")

  defp dpop(:auto), do: :auto
  defp dpop(false), do: false

  defp dpop(true) do
    JWT.require!("auth: [dpop: true]")
    true
  end

  defp dpop(other),
    do: raise(ArgumentError, "auth: :dpop must be :auto, true or false, got #{inspect(other)}")

  defp par(par) when par in [:auto, false], do: par

  defp par(other),
    do: raise(ArgumentError, "auth: :par must be :auto or false, got #{inspect(other)}")

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
  defp idp(opts) when is_list(opts), do: idp(Map.new(opts))

  defp idp(%{} = opts) do
    assertion_audience!(opts[:assertion_audience], "idp:")

    unless is_nil(opts[:saml_scope]) or
             (is_list(opts[:saml_scope]) and Enum.all?(opts[:saml_scope], &is_binary/1)),
           do: raise(ArgumentError, "idp: :saml_scope must be a list of strings")

    opts
  end

  defp assertion_audience!(aud, _where)
       when aud in [nil, :issuer, :token_endpoint] or is_binary(aud),
       do: aud

  defp assertion_audience!(_aud, where),
    do:
      raise(
        ArgumentError,
        "#{where} :assertion_audience must be :issuer, :token_endpoint or a string"
      )

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
    unless is_binary(auth.client_id),
      do: raise(ArgumentError, "grant: :enterprise needs :client_id")

    check_identity_assertion!(auth)
    check_idp!(auth)
  end

  defp check_grant!(_auth), do: :ok

  defp check_identity_assertion!(auth) do
    cond do
      auth.id_token != nil and auth.saml_assertion != nil ->
        raise ArgumentError, "grant: :enterprise takes :id_token or :saml_assertion, not both"

      not (provided?(auth.id_token) or provided?(auth.saml_assertion)) ->
        raise ArgumentError,
              "grant: :enterprise needs :id_token or :saml_assertion (a token or a function)"

      true ->
        :ok
    end
  end

  defp check_idp!(auth) do
    cond do
      not (is_map(auth.idp) and
               (is_binary(auth.idp[:token_endpoint]) or is_binary(auth.idp[:issuer]))) ->
        raise ArgumentError,
              "grant: :enterprise needs idp: [token_endpoint: url] or idp: [issuer: url]"

      # The SAML exchange names the identity provider as its audience.
      auth.saml_assertion != nil and not is_binary(auth.idp[:issuer]) ->
        raise ArgumentError, "grant: :enterprise with :saml_assertion needs idp: [issuer: url]"

      true ->
        check_secret_jwt!(auth.idp[:token_endpoint_auth_method], auth.idp[:client_secret], "idp:")
    end
  end

  defp provided?(value), do: is_binary(value) or is_function(value, 1)

  # client_secret_jwt keys an HMAC with the secret, which RFC 7518 §3.2
  # wants at least as long as the hash.
  defp check_secret_jwt!("client_secret_jwt", secret, where) do
    unless Grant.hmac_key?(secret),
      do:
        raise(
          ArgumentError,
          "#{where} client_secret_jwt needs a :client_secret of at least 32 bytes"
        )
  end

  defp check_secret_jwt!(_method, _secret, _where), do: :ok

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

  # ---- before a request, and on a 401 or a 403

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
  # from. A person's grant without one waits for the 401, which asks the
  # person again.
  def fresh(%__MODULE__{grant: grant, token: %{"expires_at" => at} = token} = auth)
      when grant not in [:authorization_code, :device] and is_integer(at) do
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
  @spec unauthorized(t(), Challenge.t(), boolean()) ::
          {:ok, t()} | {:error, term(), t()} | :exhausted
  def unauthorized(%__MODULE__{static: true}, _challenge, _refresh?), do: :exhausted

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
  def insufficient_scope(%__MODULE__{static: true}, _challenge), do: :exhausted

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

  # A resource that takes DPoP-bound tokens only refuses every token a
  # client without DPoP could get: the flow stops before anyone is asked.
  defp authorize(auth, %{dpop_required: true}, _scopes)
       when auth.dpop == false,
       do: {:error, {:dpop_required, :dpop_off}, auth}

  defp authorize(auth, %{dpop_required: true} = server, scopes) do
    if DPoP.available?(),
      do: authorize_granted(auth, server, scopes),
      else: {:error, {:dpop_required, :no_jose}, auth}
  end

  defp authorize(auth, server, scopes), do: authorize_granted(auth, server, scopes)

  defp authorize_granted(%__MODULE__{grant: :authorization_code} = auth, server, scopes),
    do: authorize_code(auth, server, scopes)

  defp authorize_granted(%__MODULE__{grant: :device} = auth, server, scopes),
    do: authorize_device(auth, server, scopes)

  # `offline_access` asks for a refresh token, which no machine grant gets.
  defp authorize_granted(auth, server, scopes) do
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
        pem = new_key(auth, server)

        with {:ok, url, request} <- start_code(auth, server, registration, scopes, pem),
             {:ok, params} <- interact(auth.authorize, url),
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

  # RFC 9126: the request is pushed to the server, with a DPoP proof
  # when the client uses DPoP (which binds the code to its key), and the
  # browser carries only its request_uri.
  defp start_code(auth, server, registration, scopes, pem) do
    if push?(auth, server.metadata) do
      endpoint = server.metadata["pushed_authorization_request_endpoint"]
      dpop = proofs(auth, pem, endpoint)
      Grant.push(server, registration, auth.redirect_uri, scopes, auth.req, dpop)
    else
      {url, request} = Grant.request(server, registration, auth.redirect_uri, scopes)
      {:ok, url, request}
    end
  end

  # Whenever the server takes pushed requests, unless `par: false`; a
  # server that requires them gets them whatever `par:` says.
  defp push?(auth, metadata) do
    is_binary(metadata["pushed_authorization_request_endpoint"]) and
      (auth.par == :auto or metadata["require_pushed_authorization_requests"] == true)
  end

  # RFC 8628: the device authorization request, the person told where to
  # go, then the token endpoint polled until they decide.
  defp authorize_device(auth, server, scopes) do
    with true <-
           is_binary(server.metadata["device_authorization_endpoint"]) ||
             {:error, :no_device_endpoint, auth},
         {:ok, registration, auth} <- Registration.client(auth, server) do
      pem = new_key(auth, server)

      with {:ok, start} <- Grant.device_authorization(server, registration, scopes, auth.req),
           _ = prompt(auth.device_prompt, start),
           {:ok, body} <-
             poll(
               auth,
               server,
               registration,
               start,
               proofs(auth, pem, server.metadata["token_endpoint"])
             ) do
        {:ok, put(auth, {:token, auth.url}, token(body, server, registration, scopes, pem))}
      else
        {:error, reason} -> {:error, reason, auth}
      end
    end
  end

  defp prompt(device_prompt, start) do
    device_prompt.(
      Map.take(start, [:user_code, :verification_uri, :verification_uri_complete, :expires_in])
    )
  end

  # RFC 8628 §3.5: the first poll waits `interval` too, and the device
  # code is not worth polling with once `expires_in` is over.
  defp poll(auth, server, registration, start, dpop) do
    deadline = System.monotonic_time(:millisecond) + start.expires_in * 1_000
    poll(auth, server, registration, start.device_code, dpop, start.interval, deadline)
  end

  defp poll(auth, server, registration, code, dpop, interval, deadline) do
    auth.sleep.(interval * 1_000)

    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :expired_token}
    else
      case Grant.device_token(server, registration, code, auth.req, dpop) do
        {:ok, body} ->
          {:ok, body}

        {:error, {:token_failed, 400, %{"error" => "authorization_pending"}}} ->
          poll(auth, server, registration, code, dpop, interval, deadline)

        {:error, {:token_failed, 400, %{"error" => "slow_down"}}} ->
          poll(auth, server, registration, code, dpop, interval + @slow_down, deadline)

        {:error, {:token_failed, 400, %{"error" => "access_denied"}}} ->
          {:error, :access_denied}

        {:error, {:token_failed, 400, %{"error" => "expired_token"}}} ->
          {:error, :expired_token}

        {:error, reason} ->
          {:error, reason}
      end
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
      {:ok, body, auth} ->
        {:ok, put(auth, {:token, auth.url}, token(body, server, registration, scopes, pem))}

      {:error, reason, auth} ->
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
       do: with_auth(Grant.client_credentials(server, registration, scopes, auth.req, dpop), auth)

  defp machine_token(%__MODULE__{grant: :jwt_bearer} = auth, server, registration, scopes, dpop) do
    result =
      with {:ok, jwt} <- provide(auth.assertion, server),
           do: Grant.jwt_bearer(server, registration, jwt, scopes, auth.req, dpop)

    with_auth(result, auth)
  end

  # The token exchange at the identity provider carries no proof: the
  # ID-JAG it returns is not presented to anyone but the authorization
  # server, whose own token is the one bound.
  defp machine_token(%__MODULE__{grant: :enterprise} = auth, server, registration, scopes, dpop) do
    with {:ok, idp} <- Enterprise.resolve(auth.idp, auth.req),
         {:ok, jag, auth} <- id_jag(auth, idp, server, scopes) do
      with_auth(Grant.jwt_bearer(server, registration, jag, scopes, auth.req, dpop), auth)
    else
      {:error, reason, auth} -> {:error, reason, auth}
      {:error, reason} -> {:error, reason, auth}
    end
  end

  defp with_auth({:ok, body}, auth), do: {:ok, body, auth}
  defp with_auth({:error, reason}, auth), do: {:error, reason, auth}

  # An ID token is exchanged for the ID-JAG as it is.
  defp id_jag(%__MODULE__{saml_assertion: nil} = auth, idp, server, scopes) do
    result =
      with {:ok, id_token} <- provide(auth.id_token, server),
           do: Enterprise.exchange(idp, {:id_token, id_token}, server, scopes, auth.req)

    with_auth(result, auth)
  end

  # A SAML assertion goes through the identity provider's refresh token
  # (draft-ietf-oauth-identity-assertion-authz-grant §4.5), which is kept
  # (in the session and the store): later authorizations, a renewal or a
  # step-up, exchange it again for a new ID-JAG while it lasts, and need
  # no assertion. One the provider no longer takes (`invalid_grant`, RFC
  # 8693 §2.2.2) is dropped and the assertion traded again, once.
  defp id_jag(auth, idp, server, scopes) do
    case idp_token(auth) do
      nil ->
        saml(auth, idp, server, scopes)

      %{"refresh_token" => refresh} = token ->
        case Enterprise.exchange(idp, {:refresh_token, refresh}, server, scopes, auth.req) do
          {:ok, jag} ->
            {:ok, jag, auth}

          {:error, {:token_exchange_failed, 400, %{"error" => "invalid_grant"}}} ->
            auth = put(auth, {:idp, idp.issuer}, Map.delete(token, "refresh_token"))
            saml(auth, idp, server, scopes)

          {:error, reason} ->
            {:error, reason, auth}
        end
    end
  end

  defp saml(auth, idp, server, scopes) do
    with {:ok, assertion} <- provide(auth.saml_assertion, server),
         {:ok, idp_token} <- Enterprise.saml(idp, assertion, auth.req) do
      auth = put(auth, {:idp, idp.issuer}, idp_token)

      with_auth(
        Enterprise.exchange(
          idp,
          {:refresh_token, idp_token["refresh_token"]},
          server,
          scopes,
          auth.req
        ),
        auth
      )
    else
      {:error, reason} -> {:error, reason, auth}
    end
  end

  # The identity provider's refresh token, while it has not expired, and
  # only for the provider and the client at it that it was issued to.
  defp idp_token(auth) do
    case fetch(auth, {:idp, auth.idp.issuer}) do
      %{"refresh_token" => refresh, "client_id" => client_id} = token
      when is_binary(refresh) ->
        if client_id == auth.idp[:client_id] and not expired?(token["expires_at"]),
          do: token

      _ ->
        nil
    end
  end

  defp expired?(at) when is_integer(at), do: System.system_time(:second) >= at - @expiry_margin
  defp expired?(_at), do: false

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
  # this server at all: when asked to, when the resource requires it (its
  # authorization server must then bind tokens whatever its metadata
  # says, and ES256 is the algorithm every DPoP server takes), or when
  # the authorization server offers ES256.
  defp new_key(%__MODULE__{dpop: false}, _server), do: nil

  defp new_key(auth, server) do
    cond do
      not DPoP.available?() ->
        nil

      auth.dpop == true or Map.get(server, :dpop_required) == true ->
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

  def fetch(%__MODULE__{idp_token: %{"issuer" => issuer} = token}, {:idp, issuer}), do: token
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

  def put(auth, {:idp, _issuer} = key, value) do
    persist(auth, key, value)
    %{auth | idp_token: value}
  end

  defp persist(%__MODULE__{store: {module, arg}}, key, value),
    do: :ok = module.put(arg, key, value)

  defp persist(_auth, _key, _value), do: :ok
end
