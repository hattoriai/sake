defmodule Sake.Client.Auth.Grant do
  @moduledoc false
  # The authorization code grant from the client's side: the request
  # (PKCE, state, resource, scope), the checks on the answer that comes
  # back through the redirect URI, and the token endpoint (the code
  # exchange and refresh, the client credentials and JWT bearer grants,
  # with the client authentication the registration calls for). The
  # device authorization grant's two requests too (RFC 8628): the device
  # authorization request, and one poll of the token endpoint. And the
  # pushed authorization request (RFC 9126), which starts the code flow
  # at the server in place of the browser.
  #
  # Every token request takes `dpop`: nil, or `%{key: key, nonce: nonce}`
  # to send a DPoP proof (RFC 9449 §5) made with `key`, and so ask for a
  # token bound to it, with the authorization server's latest nonce if
  # the client has one.

  alias Sake.Auth.{DPoP, JWT}
  alias Sake.Client.Auth.{HTTP, IDToken}

  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @device_code "urn:ietf:params:oauth:grant-type:device_code"
  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

  # A client assertion is good for one request, sent at once.
  @assertion_lifetime 60

  @doc "A PKCE verifier (32 random bytes, 43 characters) and its S256 challenge."
  @spec pkce() :: {String.t(), String.t()}
  def pkce do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    {verifier, challenge(verifier)}
  end

  @spec challenge(String.t()) :: String.t()
  def challenge(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

  @doc """
  Starts an authorization request. Returns the URL to send the person to
  and the record the answer is checked against: the state, the PKCE
  verifier and the issuer recorded from the validated metadata
  (RFC 9207), kept together as the specification asks.
  """
  @spec request(map(), map(), String.t(), [String.t()], step_up()) :: {String.t(), map()}
  def request(server, registration, redirect_uri, scopes, step_up \\ nil) do
    {params, request} = authorization(server, registration, redirect_uri, scopes, step_up)
    {authorize_url(server, params), request}
  end

  @typedoc """
  How the person must sign in, from an `insufficient_user_authentication`
  challenge (RFC 9470): its `acr_values` and `max_age`, sent as the
  authorization request's parameters of those names; nil for neither.
  """
  @type step_up :: %{acr_values: [String.t()], max_age: non_neg_integer() | nil} | nil

  defp step_up_params(nil), do: []

  defp step_up_params(step_up) do
    if(step_up.acr_values == [], do: [], else: [acr_values: Enum.join(step_up.acr_values, " ")]) ++
      if step_up.max_age == nil, do: [], else: [max_age: to_string(step_up.max_age)]
  end

  @doc """
  Starts an authorization request by pushing it (RFC 9126) to the
  server's `pushed_authorization_request_endpoint`, with the client
  authentication of the token endpoint, and a DPoP proof with `dpop`
  (which binds the code to its key, RFC 9449 §10). Returns the URL to
  send the person to, which carries only the `client_id` and the
  `request_uri`, and the record the answer is checked against, as
  `request/4` does.
  """
  @spec push(map(), map(), String.t(), [String.t()], keyword(), dpop(), step_up()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def push(server, registration, redirect_uri, scopes, req, dpop \\ nil, step_up \\ nil) do
    {params, request} = authorization(server, registration, redirect_uri, scopes, step_up)
    endpoint = server.metadata["pushed_authorization_request_endpoint"]

    # The client authentication adds the client_id where it goes.
    params = Keyword.delete(params, :client_id)
    audience = server.metadata["token_endpoint"]

    case post(endpoint, params, registration, req, dpop, false, audience) do
      {:ok, status, %{"request_uri" => request_uri}, _headers}
      when status in [200, 201] and is_binary(request_uri) ->
        url =
          authorize_url(server, client_id: registration["client_id"], request_uri: request_uri)

        {:ok, url, request}

      {:ok, status, body, _headers} ->
        {:error, {:par_failed, status, body}}

      {:error, reason} ->
        {:error, {:par_failed, reason}}
    end
  end

  # A request for `openid` sends a nonce (OpenID Connect Core §3.1.2.1),
  # which the ID token must carry back.
  defp authorization(server, registration, redirect_uri, scopes, step_up) do
    {verifier, challenge} = pkce()
    state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    nonce = if "openid" in scopes, do: IDToken.nonce()

    params =
      [
        response_type: "code",
        client_id: registration["client_id"],
        redirect_uri: redirect_uri,
        code_challenge: challenge,
        code_challenge_method: "S256",
        state: state,
        resource: server.resource
      ] ++
        if(scopes == [], do: [], else: [scope: Enum.join(scopes, " ")]) ++
        if(nonce, do: [nonce: nonce], else: []) ++ step_up_params(step_up)

    {params,
     %{
       state: state,
       nonce: nonce,
       verifier: verifier,
       redirect_uri: redirect_uri,
       issuer: server.issuer,
       iss_required: server.metadata["authorization_response_iss_parameter_supported"] == true
     }}
  end

  defp authorize_url(server, params) do
    server.metadata["authorization_endpoint"]
    |> URI.parse()
    |> URI.append_query(URI.encode_query(params, :rfc3986))
    |> URI.to_string()
  end

  @doc """
  Checks the parameters of the authorization response and returns the
  code. The `iss` check comes first and an `error` is only read after it
  passed: a response from the wrong server is not acted on at all, not
  even to report its error (RFC 9207 §2.4). `iss` is compared as a plain
  string, with no URL normalization.
  """
  @spec callback(map(), map()) :: {:ok, String.t()} | {:error, term()}
  def callback(params, request) do
    iss = params["iss"]

    cond do
      is_binary(iss) and iss != request.issuer ->
        {:error, {:issuer_mismatch, request.issuer, iss}}

      request.iss_required and not is_binary(iss) ->
        {:error, :missing_iss}

      params["state"] != request.state ->
        {:error, :state_mismatch}

      is_binary(params["error"]) ->
        {:error, {:denied, params["error"], params["error_description"]}}

      is_binary(params["code"]) ->
        {:ok, params["code"]}

      true ->
        {:error, :no_code}
    end
  end

  @typedoc "Whether a token request carries a DPoP proof, and with which key and nonce."
  @type dpop :: %{key: JWT.key(), nonce: String.t() | nil} | nil

  @doc "Exchanges a code for a token."
  @spec exchange(map(), map(), map(), String.t(), keyword(), dpop()) ::
          {:ok, map()} | {:error, term()}
  def exchange(server, registration, request, code, req, dpop \\ nil) do
    token(
      server.metadata["token_endpoint"],
      [
        grant_type: "authorization_code",
        code: code,
        redirect_uri: request.redirect_uri,
        code_verifier: request.verifier,
        resource: server.resource
      ],
      registration,
      req,
      dpop
    )
  end

  @doc "Uses a refresh token."
  @spec refresh(String.t(), map(), String.t(), String.t(), keyword(), dpop()) ::
          {:ok, map()} | {:error, term()}
  def refresh(endpoint, registration, refresh_token, resource, req, dpop \\ nil) do
    token(
      endpoint,
      [grant_type: "refresh_token", refresh_token: refresh_token, resource: resource],
      registration,
      req,
      dpop
    )
  end

  @doc "The client credentials grant (RFC 6749 §4.4)."
  @spec client_credentials(map(), map(), [String.t()], keyword(), dpop()) ::
          {:ok, map()} | {:error, term()}
  def client_credentials(server, registration, scopes, req, dpop \\ nil) do
    token(
      server.metadata["token_endpoint"],
      [grant_type: "client_credentials", resource: server.resource] ++ scope(scopes),
      registration,
      req,
      dpop
    )
  end

  @doc "The JWT bearer grant (RFC 7523 §2.1): `assertion` is the JWT."
  @spec jwt_bearer(map(), map(), String.t(), [String.t()], keyword(), dpop()) ::
          {:ok, map()} | {:error, term()}
  def jwt_bearer(server, registration, assertion, scopes, req, dpop \\ nil) do
    token(
      server.metadata["token_endpoint"],
      [grant_type: @jwt_bearer, assertion: assertion, resource: server.resource] ++
        scope(scopes),
      registration,
      req,
      dpop
    )
  end

  @doc """
  A device authorization request (RFC 8628 §3.1) to the server's
  `device_authorization_endpoint`, with the client authentication of
  the token endpoint (a client assertion's audience is the token
  endpoint's server). Returns the response's fields as atoms, with an
  `interval` of 5 seconds when the server names none (§3.2).
  """
  @spec device_authorization(map(), map(), [String.t()], keyword(), step_up()) ::
          {:ok, map()} | {:error, term()}
  def device_authorization(server, registration, scopes, req, step_up \\ nil) do
    endpoint = server.metadata["device_authorization_endpoint"]

    {form, headers} =
      authenticate(
        [resource: server.resource] ++ scope(scopes) ++ step_up_params(step_up),
        registration,
        server.metadata["token_endpoint"]
      )

    case HTTP.post(endpoint, [form: form], headers, req) do
      {:ok, 200,
       %{"device_code" => code, "user_code" => user_code, "verification_uri" => uri} = body,
       _headers}
      when is_binary(code) and is_binary(user_code) and is_binary(uri) ->
        with {:ok, expires_in} <- seconds(body["expires_in"], nil),
             {:ok, interval} <- seconds(body["interval"], 5) do
          {:ok,
           %{
             device_code: code,
             user_code: user_code,
             verification_uri: uri,
             verification_uri_complete:
               if(is_binary(body["verification_uri_complete"]),
                 do: body["verification_uri_complete"]
               ),
             expires_in: expires_in,
             interval: interval
           }}
        else
          :error -> {:error, {:device_authorization_failed, 200, body}}
        end

      {:ok, status, body, _headers} ->
        {:error, {:device_authorization_failed, status, body}}

      {:error, reason} ->
        {:error, {:device_authorization_failed, reason}}
    end
  end

  defp seconds(n, _default) when is_integer(n) and n > 0, do: {:ok, n}
  defp seconds(nil, default) when is_integer(default), do: {:ok, default}
  defp seconds(_n, _default), do: :error

  @doc """
  One poll of the token endpoint with a device code (RFC 8628 §3.4). An
  answer still pending is an error like any other, `{:token_failed,
  400, %{"error" => "authorization_pending"}}`, for the caller to wait
  on.
  """
  @spec device_token(map(), map(), String.t(), keyword(), dpop()) ::
          {:ok, map()} | {:error, term()}
  def device_token(server, registration, device_code, req, dpop \\ nil) do
    token(
      server.metadata["token_endpoint"],
      [grant_type: @device_code, device_code: device_code],
      registration,
      req,
      dpop
    )
  end

  defp scope([]), do: []
  defp scope(scopes), do: [scope: Enum.join(scopes, " ")]

  # A DPoP token comes only in answer to a proof; a bearer one may come
  # either way, from a server that does not bind tokens.
  defp token(endpoint, params, registration, req, dpop) do
    case post(endpoint, params, registration, req, dpop, false) do
      {:ok, 200, %{"access_token" => access, "token_type" => type} = body, _headers}
      when is_binary(access) and is_binary(type) ->
        case String.downcase(type) do
          "bearer" -> {:ok, body}
          "dpop" when dpop != nil -> {:ok, body}
          _ -> {:error, {:token_type, type}}
        end

      {:ok, status, body, _headers} ->
        {:error, {:token_failed, status, body}}

      {:error, reason} ->
        {:error, {:token_failed, reason}}
    end
  end

  # RFC 9449 §8: a server that wants a nonce in the proof refuses the
  # first one with `use_dpop_nonce` and the nonce to use, and the request
  # is made once more with it. The client authenticates afresh for the
  # retry: a client assertion is single use, and the server may have
  # recorded the first one before it looked at the proof.
  #
  # `audience` is the token endpoint a client assertion names when it is
  # not the server's issuer: the endpoint itself, but for a push, whose
  # assertion is the token endpoint's (RFC 9126 §2).
  defp post(endpoint, params, registration, req, dpop, retried?, audience \\ nil) do
    {form, headers} = authenticate(params, registration, audience || endpoint)

    case HTTP.post(endpoint, [form: form], proof(dpop, endpoint) ++ headers, req) do
      {:ok, 400, %{"error" => "use_dpop_nonce"}, %{"dpop-nonce" => [nonce | _]}}
      when dpop != nil and not retried? ->
        post(endpoint, params, registration, req, %{dpop | nonce: nonce}, true, audience)

      other ->
        other
    end
  end

  defp proof(nil, _endpoint), do: []

  defp proof(%{key: key, nonce: nonce}, endpoint),
    do: [{"dpop", DPoP.proof(key, "POST", endpoint, nonce: nonce)}]

  @doc """
  Adds the client authentication a registration calls for to a token
  request to `endpoint`: its parameters, and the headers to send.
  """
  @spec authenticate(keyword(), map(), String.t()) :: {keyword(), [{String.t(), String.t()}]}
  def authenticate(params, registration, endpoint)

  # private_key_jwt (RFC 7523 §2.2): an assertion signed with the client's
  # own key.
  def authenticate(
        params,
        %{"token_endpoint_auth_method" => "private_key_jwt", "private_key" => {key, alg}} = reg,
        endpoint
      ),
      do: {params ++ client_assertion(JWT.sign(assertion_claims(reg, endpoint), key, alg)), []}

  # client_secret_jwt (RFC 7523 §2.2 with an HMAC, OpenID Connect Core
  # §9): the same assertion, signed with the client secret, so the secret
  # itself never goes on the wire.
  def authenticate(
        params,
        %{"token_endpoint_auth_method" => "client_secret_jwt", "client_secret" => secret} = reg,
        endpoint
      )
      when is_binary(secret),
      do: {params ++ client_assertion(hs256(assertion_claims(reg, endpoint), secret)), []}

  # RFC 6749 §2.3.1: the id and secret are form-encoded before they are
  # joined for HTTP Basic, so a colon in either survives the trip.
  def authenticate(
        params,
        %{"token_endpoint_auth_method" => "client_secret_basic", "client_secret" => secret} = reg,
        _endpoint
      )
      when is_binary(secret) do
    credentials = URI.encode_www_form(reg["client_id"]) <> ":" <> URI.encode_www_form(secret)

    {params, [{"authorization", "Basic " <> Base.encode64(credentials)}]}
  end

  def authenticate(
        params,
        %{"token_endpoint_auth_method" => "client_secret_post", "client_secret" => secret} = reg,
        _endpoint
      )
      when is_binary(secret),
      do: {params ++ [client_id: reg["client_id"], client_secret: secret], []}

  # A client without an identifier at all (a workload presenting only its
  # JWT grant) sends none.
  def authenticate(params, %{"client_id" => nil}, _endpoint), do: {params, []}
  def authenticate(params, reg, _endpoint), do: {params ++ [client_id: reg["client_id"]], []}

  defp client_assertion(jwt), do: [client_assertion_type: @assertion_type, client_assertion: jwt]

  # RFC 7523 §2.2 and §3: the client names itself as issuer and subject,
  # for this server, with a short expiry and a unique `jti`. No client_id
  # parameter is needed: the assertion carries it.
  defp assertion_claims(reg, endpoint) do
    now = System.system_time(:second)

    %{
      "iss" => reg["client_id"],
      "sub" => reg["client_id"],
      "aud" => audience(reg, endpoint),
      "iat" => now,
      "exp" => now + @assertion_lifetime,
      "jti" => 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    }
  end

  # The audience is the server's issuer identifier by default, as
  # draft-ietf-oauth-rfc7523bis asks: an assertion for one server's
  # issuer cannot be replayed at another's token endpoint (audience
  # injection). Some servers want their token endpoint URL instead
  # (`assertion_audience: :token_endpoint`), or another value; a server
  # known by its token endpoint alone gets that.
  defp audience(reg, endpoint) do
    case reg["assertion_audience"] do
      :token_endpoint -> endpoint
      aud when is_binary(aud) -> aud
      _issuer -> reg["issuer"] || endpoint
    end
  end

  # HS256 (RFC 7518 §3.2), for client_secret_jwt alone and by hand: Sake
  # signs with an HMAC but never verifies one (`Sake.Auth.JWT` refuses the
  # whole family, against algorithm confusion), so this stays out of the
  # general JWT code, and needs no `jose`.
  defp hs256(claims, secret) do
    input = segment(%{"alg" => "HS256"}) <> "." <> segment(claims)
    input <> "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, input), padding: false)
  end

  defp segment(map), do: map |> JSON.encode!() |> Base.url_encode64(padding: false)

  @doc """
  Whether `secret` can key client_secret_jwt: RFC 7518 §3.2 asks for an
  HS256 key at least as long as the hash, 256 bits.
  """
  @spec hmac_key?(term()) :: boolean()
  def hmac_key?(secret), do: is_binary(secret) and byte_size(secret) >= 32
end
