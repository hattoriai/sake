defmodule Sake.Auth.SigningKeys do
  @moduledoc false
  # The authorization server's own signing keys (`signing_keys:`), for
  # OpenID Connect's ID tokens, and the JWK Set that publishes them at
  # `GET {oauth_path}/jwks`.
  #
  # Each key is a PEM private key with a `kid`: RSA (RS256), P-256
  # (ES256) or P-384 (ES384), the algorithm its type signs with by
  # default (`Sake.Auth.JWT.default_alg/1`). The first key signs; every
  # key is published, so a key is rotated by putting the new one first
  # and keeping the old one until the ID tokens it signed have expired.
  # The JWK Set holds the public parts alone.
  #
  # The keys are read when the configuration is: a host whose keys are
  # missing, unreadable, weak or share a `kid` finds out when it starts.
  # Reading them needs jose, as `openid:` does.
  #
  # Core: the configuration and plain data; `Sake.Auth.PublicKeys` serves
  # the set.

  alias Sake.Auth.{Config, JWT}

  @typedoc "A signing key, read: its `kid`, the algorithm it signs with, and the key."
  @type key :: %{kid: String.t(), alg: String.t(), key: JWT.key()}

  @doc """
  The `signing_keys:` option, read and checked: the keys, in order. They
  are for `openid:` only: none with it, or any without it, raises.
  """
  @spec new(term(), boolean()) :: [key()]
  def new([], false), do: []

  def new(_keys, false),
    do: raise(ArgumentError, "signing_keys: are for OpenID Connect: add openid: true")

  def new(keys, true) when is_list(keys) and keys != [] do
    JWT.require!("signing_keys:")
    keys = Enum.map(keys, &key/1)
    kids = Enum.map(keys, & &1.kid)

    if Enum.uniq(kids) != kids,
      do: raise(ArgumentError, "signing_keys: each key needs a kid of its own")

    keys
  end

  def new(_keys, true),
    do:
      raise(
        ArgumentError,
        "openid: needs signing_keys: [[kid: \"...\", pem: pem]], the keys ID tokens are signed with"
      )

  defp key(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: key(Map.new(opts)), else: bad_key!(opts)
  end

  defp key(%{kid: kid, pem: pem} = opts)
       when is_binary(kid) and kid != "" and map_size(opts) == 2 do
    case JWT.private_key(pem) do
      {:ok, key} ->
        %{kid: kid, alg: JWT.default_alg(key), key: key}

      {:error, :invalid_key} ->
        raise ArgumentError,
              "signing_keys: the key #{inspect(kid)} must be a PEM private key: " <>
                "RSA of 2048 bits or more, P-256 or P-384"
    end
  end

  defp key(other), do: bad_key!(other)

  defp bad_key!(other),
    do:
      raise(
        ArgumentError,
        "signing_keys: each key is [kid: string, pem: pem], got #{inspect(other)}"
      )

  @doc "The key that signs: the first."
  @spec current(Config.t()) :: key()
  def current(%Config{signing_keys: [key | _]}), do: key

  @doc "The algorithms the keys sign with, for the metadata."
  @spec algs(Config.t()) :: [String.t()]
  def algs(%Config{signing_keys: keys}), do: keys |> Enum.map(& &1.alg) |> Enum.uniq()

  @doc """
  The JWK Set of every key (RFC 7517 §5): the public parts, each with
  its `kid`, its `alg` and `use: sig`.
  """
  @spec jwks(Config.t()) :: %{String.t() => [map()]}
  def jwks(%Config{signing_keys: keys}) do
    %{
      "keys" =>
        Enum.map(keys, fn key ->
          key.key
          |> JWT.public_jwk()
          |> Map.take(~w(kty crv x y n e))
          |> Map.merge(%{"kid" => key.kid, "alg" => key.alg, "use" => "sig"})
        end)
    }
  end

  @doc "Signs `claims` as a JWT (`typ: JWT`) with the current key, named by its `kid`."
  @spec sign(Config.t(), map()) :: String.t()
  def sign(config, claims) do
    key = current(config)
    JWT.sign(claims, key.key, key.alg, %{"kid" => key.kid, "typ" => "JWT"})
  end
end
