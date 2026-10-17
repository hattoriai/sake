defmodule Sake.Auth.IDToken do
  @moduledoc false
  # OpenID Connect's ID token (OpenID Connect Core 1.0 §2), which the
  # token endpoint adds to its answer when the grant's scopes include
  # `openid` and the server has `openid:`: for an authorization code, a
  # device code (RFC 8628) and a refresh.
  #
  # The claims: `iss`, the issuer; `sub`, the person's ID
  # (`c:Sake.Auth.Subject.id/1`, as the grant stored it); `aud` and
  # `azp`, the client; `iat` and `exp` (`id_token_ttl` later); how the
  # person signed in (RFC 9470's `acr` and `auth_time`, when known);
  # the authorization request's `nonce`, when it sent one; and `at_hash`
  # (§3.1.3.6), which ties the ID token to the access token issued with
  # it. A refresh issues a new ID token with the grant's `auth_time` and
  # `acr`, since it is no new sign-in, and without a nonce (§12.2); so
  # does a device grant, which has no nonce at all.
  #
  # The profile and email claims are not in it: the client asks the
  # userinfo endpoint (`Sake.Auth.Claims`).
  #
  # Signed with the first of `signing_keys:` (`Sake.Auth.SigningKeys`).
  #
  # Core: the configuration and the grant's attributes.

  alias Sake.Auth.{Config, SigningKeys}

  @doc """
  Whether a grant gets an ID token: the server has `openid:`, the scopes
  include `openid`, and there is a person (a machine client has none).
  """
  @spec issued?(Config.t(), map()) :: boolean()
  def issued?(%Config{openid: false}, _attrs), do: false

  def issued?(_config, attrs),
    do: "openid" in attrs.scopes and is_binary(attrs[:subject_id])

  @doc """
  The ID token of a grant: `attrs` are its client_id, subject_id, and
  optionally acr, auth_time and nonce; `access_token` is the access
  token issued with it, for `at_hash`.
  """
  @spec issue(Config.t(), map(), String.t()) :: String.t()
  def issue(config, attrs, access_token) do
    now = System.system_time(:second)
    key = SigningKeys.current(config)

    %{
      "iss" => config.issuer,
      "sub" => attrs.subject_id,
      "aud" => attrs.client_id,
      "azp" => attrs.client_id,
      "iat" => now,
      "exp" => now + config.openid.id_token_ttl,
      "at_hash" => at_hash(access_token, key.alg)
    }
    |> put("auth_time", attrs[:auth_time] && DateTime.to_unix(attrs[:auth_time]))
    |> put("acr", attrs[:acr])
    |> put("nonce", attrs[:nonce])
    |> then(&SigningKeys.sign(config, &1))
  end

  @doc """
  `at_hash` (OpenID Connect Core §3.1.3.6): the left half of the hash of
  the access token, with the hash of the signing algorithm (SHA-256 for
  RS256 and ES256, SHA-384 for ES384), base64url-encoded.
  """
  @spec at_hash(String.t(), String.t()) :: String.t()
  def at_hash(access_token, alg) do
    digest = :crypto.hash(hash(alg), access_token)

    digest
    |> binary_part(0, div(byte_size(digest), 2))
    |> Base.url_encode64(padding: false)
  end

  defp hash("ES384"), do: :sha384
  defp hash(_alg), do: :sha256

  defp put(claims, _name, nil), do: claims
  defp put(claims, name, value), do: Map.put(claims, name, value)
end
