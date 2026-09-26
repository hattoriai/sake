defmodule Sake.Auth.ClientAuth do
  @moduledoc false
  # Identifies the client at the token and revocation endpoints: a public
  # client by client_id, a confidential client by its secret (basic or post).

  alias Sake.Auth.{Clients, Tokens}

  @spec authenticate(Sake.Auth.Config.t(), Plug.Conn.t(), map()) ::
          {:ok, Sake.Auth.Client.t()} | {:error, :invalid_client}
  def authenticate(config, conn, params) do
    {id, secret} =
      case Plug.Conn.get_req_header(conn, "authorization") do
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

  defp secret_ok?(%{token_endpoint_auth_method: "none"}, _secret), do: true

  defp secret_ok?(%{secret_hash: hash}, secret) when is_binary(hash) and is_binary(secret),
    do: Plug.Crypto.secure_compare(hash, Tokens.hash(secret))

  defp secret_ok?(_, _), do: false
end
