defmodule Sake.Client.Auth.Enterprise do
  @moduledoc false
  # Enterprise-managed authorization from the client's side: the person's
  # identity assertion (from the host's own single sign-on) is exchanged
  # at the enterprise identity provider for an Identity Assertion JWT
  # Authorization Grant (RFC 8693 token exchange), which the MCP
  # authorization server then takes as a JWT bearer grant.
  #
  # The assertion is an OpenID Connect ID token, exchanged directly, or a
  # SAML 2.0 assertion, which is first traded for a refresh token at the
  # identity provider, and that refresh token then for the ID-JAG
  # (draft-ietf-oauth-identity-assertion-authz-grant §4.5). Sake never
  # reads the SAML assertion: it is opaque here, as the ID token is.

  alias Sake.Client.Auth.{Discovery, Grant, HTTP}

  @token_exchange "urn:ietf:params:oauth:grant-type:token-exchange"
  @id_jag "urn:ietf:params:oauth:token-type:id-jag"
  @id_token "urn:ietf:params:oauth:token-type:id_token"
  @refresh_token "urn:ietf:params:oauth:token-type:refresh_token"
  @saml2 "urn:ietf:params:oauth:token-type:saml2"

  @typedoc "The token presented to the identity provider for an ID-JAG."
  @type subject :: {:id_token, String.t()} | {:refresh_token, String.t()}

  @doc """
  The identity provider's token endpoint, and the client authentication
  methods its metadata lists (nil when it was given directly), read once
  for the exchanges of one authorization.
  """
  @spec resolve(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(%{token_endpoint: endpoint} = idp, _req) when is_binary(endpoint),
    do: {:ok, Map.put(idp, :auth_methods, nil)}

  def resolve(%{issuer: issuer} = idp, req) do
    case Discovery.issuer_metadata(issuer, req) do
      {:ok, %{"token_endpoint" => endpoint} = metadata} when is_binary(endpoint) ->
        {:ok,
         Map.merge(idp, %{
           token_endpoint: endpoint,
           auth_methods: metadata["token_endpoint_auth_methods_supported"]
         })}

      {:ok, _metadata} ->
        {:error, {:token_exchange_failed, :no_token_endpoint}}

      {:error, reason} ->
        {:error, {:token_exchange_failed, reason}}
    end
  end

  @doc """
  Exchanges an ID token, or the identity provider's refresh token from a
  SAML exchange, at the resolved identity provider for an ID-JAG for
  `server`: its issuer as the `audience` and its resource as the
  `resource`, as the profile asks.
  """
  @spec exchange(map(), subject(), map(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def exchange(idp, {type, token}, server, scopes, req) do
    params =
      [
        grant_type: @token_exchange,
        requested_token_type: @id_jag,
        audience: server.issuer,
        resource: server.resource,
        subject_token: token,
        subject_token_type: if(type == :id_token, do: @id_token, else: @refresh_token)
      ] ++ if(scopes == [], do: [], else: [scope: Enum.join(scopes, " ")])

    case post(idp, params, req) do
      {:ok, 200, %{"access_token" => jag, "issued_token_type" => @id_jag}, _headers}
      when is_binary(jag) ->
        {:ok, jag}

      {:ok, status, body, _headers} ->
        {:error, {:token_exchange_failed, status, body}}

      {:error, reason} ->
        {:error, {:token_exchange_failed, reason}}
    end
  end

  @doc """
  Trades a SAML 2.0 assertion for a refresh token at the resolved
  identity provider (draft-ietf-oauth-identity-assertion-authz-grant
  §4.5): a token exchange with the assertion as the subject token, typed
  `saml2` (RFC 8693 §3: the base64url-encoded assertion, as the caller
  gives it), for the provider itself as the audience, asking for a
  refresh token. Returns the refresh token, its expiry (`expires_in`,
  which here is the issued token's, when the provider sends one) and the
  provider and client it belongs to.
  """
  @spec saml(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def saml(idp, assertion, req) do
    params =
      [
        grant_type: @token_exchange,
        requested_token_type: @refresh_token,
        audience: idp.issuer,
        subject_token: assertion,
        subject_token_type: @saml2
      ] ++ saml_scope(idp[:saml_scope])

    case post(idp, params, req) do
      {:ok, 200, %{"issued_token_type" => @refresh_token} = body, _headers} ->
        case issued_refresh_token(body) do
          nil ->
            {:error, {:saml_exchange_failed, :no_refresh_token}}

          refresh ->
            {:ok,
             %{
               "refresh_token" => refresh,
               "expires_at" => expires_at(body["expires_in"]),
               "issuer" => idp.issuer,
               "client_id" => idp[:client_id]
             }}
        end

      # A successful answer of another kind is not passed on: it may hold
      # a token, and an error is something a caller may log.
      {:ok, 200, body, _headers} ->
        {:error, {:saml_exchange_failed, {:issued_token_type, body["issued_token_type"]}}}

      {:ok, status, body, _headers} ->
        {:error, {:saml_exchange_failed, status, body}}

      {:error, reason} ->
        {:error, {:saml_exchange_failed, reason}}
    end
  end

  # Some providers issue a refresh token only when `offline_access` is
  # asked for: `saml_scope:` is the scope of this exchange alone, and
  # none is sent without it.
  defp saml_scope(nil), do: []
  defp saml_scope([]), do: []
  defp saml_scope(scopes), do: [scope: Enum.join(scopes, " ")]

  # RFC 8693 §2.2.1 carries the issued token in `access_token`, whatever
  # its type; an identity provider may also (or instead) answer a request
  # for a refresh token in the `refresh_token` member of RFC 6749 §5.1.
  # Either is taken, the specific member first, and the "N_A" placeholder
  # of a response that has no access token is not a token.
  defp issued_refresh_token(body) do
    Enum.find([body["refresh_token"], body["access_token"]], fn token ->
      is_binary(token) and token not in ["", "N_A"]
    end)
  end

  defp expires_at(seconds) when is_integer(seconds) and seconds > 0,
    do: System.system_time(:second) + seconds

  defp expires_at(_seconds), do: nil

  defp post(idp, params, req) do
    {params, headers} = Grant.authenticate(params, registration(idp), idp.token_endpoint)
    HTTP.post(idp.token_endpoint, [form: params], headers, req)
  end

  # The client's credentials at the identity provider, sent the way its
  # metadata says it takes them (RFC 8414 §2: `client_secret_basic` when
  # it does not say), or as the key of a client_secret_jwt assertion when
  # that is the only secret method it lists. A client assertion is for
  # the provider's issuer, or its token endpoint when only that is known
  # or `assertion_audience: :token_endpoint` asks for it (RFC 7523 §3
  # allows either).
  defp registration(idp) do
    secret = idp[:client_secret]

    method =
      cond do
        idp[:token_endpoint_auth_method] -> idp.token_endpoint_auth_method
        is_binary(secret) -> secret_method(idp.auth_methods, secret)
        true -> "none"
      end

    %{
      "client_id" => idp[:client_id],
      "client_secret" => secret,
      "token_endpoint_auth_method" => method,
      "issuer" => idp[:issuer],
      "assertion_audience" => idp[:assertion_audience]
    }
  end

  defp secret_method(methods, secret) do
    methods = List.wrap(methods || "client_secret_basic")

    cond do
      "client_secret_basic" in methods -> "client_secret_basic"
      "client_secret_post" in methods -> "client_secret_post"
      "client_secret_jwt" in methods and Grant.hmac_key?(secret) -> "client_secret_jwt"
      true -> "client_secret_post"
    end
  end
end
