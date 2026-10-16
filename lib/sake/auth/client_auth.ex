defmodule Sake.Auth.ClientAuth do
  @moduledoc false
  # Identifies the client at the token and revocation endpoints: a public
  # client by client_id, a confidential client by its secret (basic or
  # post), or by a JWT it signed with its own key (`private_key_jwt`,
  # RFC 7523 §2.2).

  alias Sake.Auth.{Clients, Config, JWKS, JWT, Replay, Tokens}

  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

  @spec authenticate(Config.t(), Plug.Conn.t(), map()) ::
          {:ok, Sake.Auth.Client.t()} | {:error, :invalid_client}
  def authenticate(config, conn, params) do
    basic = Plug.Conn.get_req_header(conn, "authorization")

    cond do
      # RFC 6749 §2.3: a client uses one authentication method per request.
      params["client_assertion_type"] != nil and basic != [] -> {:error, :invalid_client}
      params["client_assertion_type"] != nil -> assertion(config, params)
      true -> secret(config, basic, params)
    end
  end

  @doc "Whether the request carries any client identification at all."
  @spec client_given?(Plug.Conn.t(), map()) :: boolean()
  def client_given?(conn, params) do
    match?(["Basic " <> _], Plug.Conn.get_req_header(conn, "authorization")) or
      is_binary(params["client_id"]) or is_binary(params["client_assertion"])
  end

  # ---- client_id and secret

  defp secret(config, basic, params) do
    {id, secret} =
      case basic do
        ["Basic " <> encoded] ->
          with {:ok, decoded} <- Base.decode64(encoded),
               [id, secret] <- String.split(decoded, ":", parts: 2) do
            {URI.decode_www_form(id), URI.decode_www_form(secret)}
          else
            _ -> {nil, nil}
          end

        _ ->
          {params["client_id"], params["client_secret"]}
      end

    with true <- is_binary(id),
         {:ok, client} <- Clients.resolve(config, id),
         true <- secret_ok?(client, secret) do
      {:ok, client}
    else
      _ -> {:error, :invalid_client}
    end
  end

  # A client registered for `private_key_jwt` has no secret, and is never
  # let in by its client_id alone.
  defp secret_ok?(%{token_endpoint_auth_method: "none"}, _secret), do: true

  defp secret_ok?(%{token_endpoint_auth_method: method, secret_hash: hash}, secret)
       when method in ["client_secret_basic", "client_secret_post"] and is_binary(hash) and
              is_binary(secret),
       do: Plug.Crypto.secure_compare(hash, Tokens.hash(secret))

  defp secret_ok?(_, _), do: false

  # ---- private_key_jwt

  # The assertion names its client twice, as `iss` and `sub`; a
  # `client_id` parameter, when sent, must name the same one. Only a
  # client registered for this method is authenticated by it, with its
  # own registered keys, and the assertion must be meant for this
  # authorization server: its issuer or its token endpoint.
  defp assertion(
         config,
         %{"client_assertion_type" => @assertion_type, "client_assertion" => jwt} = params
       )
       when is_binary(jwt) do
    with true <- JWT.available?(),
         {:ok, _header, %{"sub" => id}} when is_binary(id) <- JWT.peek(jwt),
         true <- params["client_id"] in [nil, id],
         {:ok, %{token_endpoint_auth_method: "private_key_jwt"} = client} <-
           Clients.resolve(config, id),
         {:ok, claims} <-
           JWKS.verify(config, jwt, JWKS.source(client),
             iss: id,
             aud: [config.issuer, Config.token_url(config)],
             required: ["iss", "sub", "exp", "jti"]
           ),
         true <- short_lived?(config, claims),
         :ok <- Replay.once(id, to_string(claims["jti"]), claims["exp"]) do
      {:ok, client}
    else
      _ -> {:error, :invalid_client}
    end
  end

  defp assertion(_config, _params), do: {:error, :invalid_client}

  # A client assertion is meant for one request: one that claims to stay
  # valid for longer than `max_assertion_lifetime` (plus the clock leeway)
  # is refused, which also bounds how long its `jti` has to be remembered.
  defp short_lived?(config, %{"exp" => exp}),
    do: exp <= System.system_time(:second) + config.max_assertion_lifetime + JWT.leeway()
end
