defmodule Sake.Client.Auth.IDToken do
  @moduledoc false
  # OpenID Connect from the client's side (`auth: [openid: true]`): the
  # `nonce` of an authorization request for `openid`, and the checks on
  # the ID token that comes back with the tokens (OpenID Connect Core 1.0
  # §3.1.3.7): its signature, with a key from the authorization server's
  # `jwks_uri`; `iss`, the server's issuer; `aud`, the client; `exp` and
  # `iat`; the `nonce` the request sent; and `at_hash`, when it has one,
  # against the access token it came with. An ID token from a refresh
  # must name the same person (`sub`) as the first one (§12.2).
  #
  # The keys are fetched with the flow's own HTTP (`Sake.Client.Auth.HTTP`)
  # each time an ID token is checked: that is once per authorization or
  # refresh, and a key the server rotated in is always there.

  alias Sake.Auth.JWT
  alias Sake.Client.Auth.HTTP

  @doc "A new nonce, for an authorization request for `openid`."
  @spec nonce() :: String.t()
  def nonce, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  Checks the ID token of a token answer `body` from the server
  `issuer` whose keys are at `jwks_uri`, for `client_id`. `expect` holds
  the `nonce` the request sent (nil for none: a device grant or a
  refresh) and the `sub` of an earlier ID token (nil for a first one).
  Returns the verified claims.
  """
  @spec verify(map(), String.t(), String.t() | nil, String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, {:invalid_id_token, term()}}
  def verify(body, issuer, jwks_uri, client_id, expect, req) do
    with {:ok, id_token} <- id_token(body),
         {:ok, keys} <- keys(jwks_uri, req),
         {:ok, claims} <-
           JWT.verify(id_token, keys,
             iss: issuer,
             aud: client_id,
             required: ~w(exp iat sub)
           ),
         :ok <- nonce(claims, expect[:nonce]),
         :ok <- same_subject(claims, expect[:sub]),
         :ok <- at_hash(id_token, claims, body["access_token"]) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, {:invalid_id_token, reason}}
    end
  end

  defp id_token(%{"id_token" => token}) when is_binary(token), do: {:ok, token}
  defp id_token(_body), do: {:error, :missing}

  defp keys(jwks_uri, req) when is_binary(jwks_uri) do
    case HTTP.get_json(jwks_uri, req) do
      {:ok, %{"keys" => keys}} when is_list(keys) -> {:ok, keys}
      _ -> {:error, :no_keys}
    end
  end

  defp keys(_jwks_uri, _req), do: {:error, :no_jwks_uri}

  # §3.1.3.7 rule 11: the nonce sent comes back, exactly.
  defp nonce(_claims, nil), do: :ok

  defp nonce(%{"nonce" => nonce}, expected) when is_binary(nonce) do
    if Plug.Crypto.secure_compare(nonce, expected), do: :ok, else: {:error, :nonce}
  end

  defp nonce(_claims, _expected), do: {:error, :nonce}

  defp same_subject(_claims, nil), do: :ok
  defp same_subject(%{"sub" => sub}, sub), do: :ok
  defp same_subject(_claims, _sub), do: {:error, :sub}

  # §3.1.3.8: the left half of the access token's hash, with the hash
  # of the ID token's algorithm.
  defp at_hash(id_token, %{"at_hash" => at_hash}, access_token) when is_binary(access_token) do
    {:ok, %{"alg" => alg}, _claims} = JWT.peek(id_token)
    digest = :crypto.hash(if(alg == "ES384", do: :sha384, else: :sha256), access_token)

    half =
      digest |> binary_part(0, div(byte_size(digest), 2)) |> Base.url_encode64(padding: false)

    if half == at_hash, do: :ok, else: {:error, :at_hash}
  end

  defp at_hash(_id_token, %{"at_hash" => _}, _access_token), do: {:error, :at_hash}
  defp at_hash(_id_token, _claims, _access_token), do: :ok
end
