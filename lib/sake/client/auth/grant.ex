defmodule Sake.Client.Auth.Grant do
  @moduledoc false
  # The authorization code grant from the client's side: the request
  # (PKCE, state, resource, scope), the checks on the answer that comes
  # back through the redirect URI, and the token endpoint (the code
  # exchange and refresh, the client credentials and JWT bearer grants,
  # with the client authentication the registration calls for).

  alias Sake.Auth.JWT
  alias Sake.Client.Auth.HTTP

  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"
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
  @spec request(map(), map(), String.t(), [String.t()]) :: {String.t(), map()}
  def request(server, registration, redirect_uri, scopes) do
    {verifier, challenge} = pkce()
    state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    params =
      [
        response_type: "code",
        client_id: registration["client_id"],
        redirect_uri: redirect_uri,
        code_challenge: challenge,
        code_challenge_method: "S256",
        state: state,
        resource: server.resource
      ] ++ if(scopes == [], do: [], else: [scope: Enum.join(scopes, " ")])

    url =
      server.metadata["authorization_endpoint"]
      |> URI.parse()
      |> URI.append_query(URI.encode_query(params, :rfc3986))
      |> URI.to_string()

    {url,
     %{
       state: state,
       verifier: verifier,
       redirect_uri: redirect_uri,
       issuer: server.issuer,
       iss_required: server.metadata["authorization_response_iss_parameter_supported"] == true
     }}
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

  @doc "Exchanges a code for a token."
  @spec exchange(map(), map(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exchange(server, registration, request, code, req) do
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
      req
    )
  end

  @doc "Uses a refresh token."
  @spec refresh(String.t(), map(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def refresh(endpoint, registration, refresh_token, resource, req) do
    token(
      endpoint,
      [grant_type: "refresh_token", refresh_token: refresh_token, resource: resource],
      registration,
      req
    )
  end

  @doc "The client credentials grant (RFC 6749 §4.4)."
  @spec client_credentials(map(), map(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def client_credentials(server, registration, scopes, req) do
    token(
      server.metadata["token_endpoint"],
      [grant_type: "client_credentials", resource: server.resource] ++ scope(scopes),
      registration,
      req
    )
  end

  @doc "The JWT bearer grant (RFC 7523 §2.1): `assertion` is the JWT."
  @spec jwt_bearer(map(), map(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def jwt_bearer(server, registration, assertion, scopes, req) do
    token(
      server.metadata["token_endpoint"],
      [grant_type: @jwt_bearer, assertion: assertion, resource: server.resource] ++
        scope(scopes),
      registration,
      req
    )
  end

  defp scope([]), do: []
  defp scope(scopes), do: [scope: Enum.join(scopes, " ")]

  defp token(endpoint, params, registration, req) do
    {params, headers} = authenticate(params, registration)

    case HTTP.post(endpoint, [form: params], headers, req) do
      {:ok, 200, %{"access_token" => access, "token_type" => type} = body}
      when is_binary(access) and is_binary(type) ->
        if String.downcase(type) == "bearer",
          do: {:ok, body},
          else: {:error, {:token_type, type}}

      {:ok, status, body} ->
        {:error, {:token_failed, status, body}}

      {:error, reason} ->
        {:error, {:token_failed, reason}}
    end
  end

  @doc """
  Adds the client authentication a registration calls for to a token
  request: its parameters, and the headers to send.
  """
  @spec authenticate(keyword(), map()) :: {keyword(), [{String.t(), String.t()}]}
  def authenticate(params, registration)

  # RFC 7523 §2.2 and §3: the client names itself as issuer and subject,
  # for this authorization server (its issuer identifier, as
  # draft-ietf-oauth-rfc7523bis asks), with a short expiry and a unique
  # `jti`. No client_id parameter is needed: the assertion carries it.
  def authenticate(
        params,
        %{"token_endpoint_auth_method" => "private_key_jwt", "private_key" => {key, alg}} = reg
      ) do
    now = System.system_time(:second)

    claims = %{
      "iss" => reg["client_id"],
      "sub" => reg["client_id"],
      "aud" => reg["issuer"],
      "iat" => now,
      "exp" => now + @assertion_lifetime,
      "jti" => 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    }

    {params ++
       [client_assertion_type: @assertion_type, client_assertion: JWT.sign(claims, key, alg)], []}
  end

  # RFC 6749 §2.3.1: the id and secret are form-encoded before they are
  # joined for HTTP Basic, so a colon in either survives the trip.
  def authenticate(
        params,
        %{"token_endpoint_auth_method" => "client_secret_basic", "client_secret" => secret} = reg
      )
      when is_binary(secret) do
    credentials = URI.encode_www_form(reg["client_id"]) <> ":" <> URI.encode_www_form(secret)

    {params, [{"authorization", "Basic " <> Base.encode64(credentials)}]}
  end

  def authenticate(
        params,
        %{"token_endpoint_auth_method" => "client_secret_post", "client_secret" => secret} = reg
      )
      when is_binary(secret),
      do: {params ++ [client_id: reg["client_id"], client_secret: secret], []}

  # A client without an identifier at all (a workload presenting only its
  # JWT grant) sends none.
  def authenticate(params, %{"client_id" => nil}), do: {params, []}
  def authenticate(params, reg), do: {params ++ [client_id: reg["client_id"]], []}
end
