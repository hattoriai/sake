defmodule Sake.Auth.JWT do
  @moduledoc false
  # Compact JWS (RFC 7515) and JWT (RFC 7519) for the few places Sake needs
  # them: client assertions (RFC 7523 §2.2), JWT authorization grants
  # (RFC 7523 §2.1, the ID-JAG), the client's own signed assertions, and
  # DPoP proofs (RFC 9449, see `Sake.Auth.DPoP`), which are verified with
  # the key in their own header.
  #
  # The signatures are `jose`'s, an optional dependency: everything that
  # touches a key goes through `Sake.Auth.JWT.JOSE`, and without `jose`
  # that module only raises. This module decides everything else: which
  # algorithms and keys are acceptable at all, and whether the claims are.
  #
  # Only asymmetric algorithms are accepted: RS256, PS256, ES256 and
  # ES384. `none` and the HMAC family are refused like any unknown `alg`
  # (an HMAC "signature" checked against a public key is the classic
  # algorithm-confusion attack), and a key is only ever tried with an `alg`
  # of its own type and, when the JWK names one, its own `alg`.
  #
  # Headers, claims and thumbprints are always `JSON`, never the host's
  # `:json_library` (see `Sake.JSON`): one fixed parser for what is about
  # to be trusted, and the exact bytes RFC 7638 hashes.

  alias Sake.Auth.JWT.JOSE, as: Backend

  @algs ~w(RS256 PS256 ES256 ES384)
  @leeway 30

  # RFC 7518 §3.3: an RSA key for RS256 or PS256 is at least 2048 bits.
  @min_rsa_bytes 256

  @type key :: term()
  @type error ::
          :malformed
          | :unsupported_alg
          | :no_key
          | :bad_signature
          | :invalid_typ
          | :expired
          | :not_yet_valid
          | :issued_in_future
          | :invalid_issuer
          | :invalid_audience
          | {:missing_claim, String.t()}

  @doc "Whether the `jose` dependency is there to sign and verify."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(JOSE)

  @doc "Raises the error a host without `jose` gets when it configures something that needs it."
  @spec require!(String.t()) :: :ok
  def require!(feature) do
    if available?(),
      do: :ok,
      else:
        raise(
          ArgumentError,
          "#{feature} needs the jose package: add {:jose, \"~> 1.11\"} to your deps"
        )
  end

  @doc "The algorithms `verify/3` accepts by default, and `sign/4` can produce."
  @spec algs() :: [String.t()]
  def algs, do: @algs

  @doc """
  The header and claims of a compact JWS, *unverified*: only for picking
  the key to verify it with (its `kid`, its issuer). Never trust them.
  """
  @spec peek(term()) :: {:ok, map(), map()} | {:error, :malformed}
  def peek(token) when is_binary(token) do
    with [h, p, s] <- String.split(token, "."),
         {:ok, header} <- json_segment(h),
         {:ok, claims} <- json_segment(p),
         {:ok, _signature} <- Base.url_decode64(s, padding: false) do
      {:ok, header, claims}
    else
      _ -> {:error, :malformed}
    end
  end

  def peek(_token), do: {:error, :malformed}

  defp json_segment(segment) do
    with {:ok, bytes} <- Base.url_decode64(segment, padding: false),
         {:ok, map} when is_map(map) <- JSON.decode(bytes) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  @doc """
  Verifies a compact JWS against a JWK Set (a `%{"keys" => [...]}` map or
  a list of JWKs) and validates its claims. Returns the claims.

  Options:

    * `:algs` — the acceptable algorithms (default all of `algs/0`).
    * `:typ` — the required `typ` header, compared without case and
      with an `application/` prefix allowed (RFC 7515 §4.1.9).
    * `:iss` — the required issuer.
    * `:aud` — a string or a list of acceptable audiences; the token's
      `aud` (a string or a list) must contain one of them.
    * `:required` — claims that must be present (default `["exp"]`).
    * `:leeway` — seconds of clock skew allowed (default 30).
    * `:now` — the current time in seconds, for tests.
  """
  @spec verify(term(), map() | [map()], keyword()) :: {:ok, map()} | {:error, error()}
  def verify(token, keys, opts \\ []) do
    with {:ok, header, claims} <- peek(token),
         {:ok, alg} <- alg(header, opts[:algs] || @algs),
         :ok <- typ(header, opts[:typ]),
         :ok <- signature(token, alg, header["kid"], keys),
         :ok <- required(claims, Keyword.get(opts, :required, ["exp"])),
         :ok <- times(claims, Keyword.get(opts, :now, System.system_time(:second)), opts),
         :ok <- issuer(claims, opts[:iss]) do
      audience(claims, opts[:aud])
    end
  end

  @doc """
  Signs `claims` as a compact JWS with a key from `private_key/1`.
  `header` adds fields (`typ`, `kid`, `jwk`) to the protected header.
  """
  @spec sign(map(), key(), String.t(), map()) :: String.t()
  def sign(claims, key, alg, header \\ %{}) when alg in @algs do
    unless key_type(public_jwk(key)) == key_type(alg),
      do: raise(ArgumentError, "this key cannot sign #{alg}")

    Backend.sign(JSON.encode!(claims), key, Map.put(header, "alg", alg))
  end

  @doc "Reads a PEM private key (PKCS #8, or a traditional RSA or EC one) of a supported type."
  @spec private_key(term()) :: {:ok, key()} | {:error, :invalid_key}
  def private_key(pem) when is_binary(pem) do
    with {:ok, key} <- Backend.private_key(pem),
         jwk = Backend.public_jwk(key),
         true <- key_type(jwk) != nil and strong?(jwk) do
      {:ok, key}
    else
      _ -> {:error, :invalid_key}
    end
  end

  def private_key(_pem), do: {:error, :invalid_key}

  @doc "The public JWK of a private key, to register with an authorization server."
  @spec public_jwk(key()) :: map()
  def public_jwk(key), do: Backend.public_jwk(key)

  @doc """
  The RFC 7638 SHA-256 thumbprint of a public JWK, base64url-encoded:
  the hash of its required members only, in lexicographic order with no
  whitespace, so the same key always has the same thumbprint whatever
  else its JWK says. It needs no `jose`.
  """
  @spec thumbprint(map()) :: String.t()
  def thumbprint(jwk) do
    members =
      case key_type(jwk) do
        :rsa -> ~w(e kty n)
        curve when curve in [:p256, :p384] -> ~w(crv kty x y)
      end

    json =
      "{" <>
        Enum.map_join(members, ",", &(JSON.encode!(&1) <> ":" <> JSON.encode!(jwk[&1]))) <> "}"

    :sha256 |> :crypto.hash(json) |> Base.url_encode64(padding: false)
  end

  @doc "The algorithm a private key signs with unless told otherwise: RS256, ES256 or ES384."
  @spec default_alg(key()) :: String.t()
  def default_alg(key) do
    case key_type(public_jwk(key)) do
      :rsa -> "RS256"
      :p256 -> "ES256"
      :p384 -> "ES384"
    end
  end

  # ---- header

  # A `crit` header lists extensions the recipient must understand; Sake
  # understands none, so a token with one is refused (RFC 7515 §4.1.11).
  defp alg(%{"crit" => _}, _algs), do: {:error, :unsupported_alg}

  defp alg(%{"alg" => alg}, algs) when is_binary(alg) do
    if alg in @algs and alg in algs, do: {:ok, alg}, else: {:error, :unsupported_alg}
  end

  defp alg(_header, _algs), do: {:error, :malformed}

  defp typ(_header, nil), do: :ok

  defp typ(%{"typ" => typ}, expected) when is_binary(typ) do
    normalized = typ |> String.downcase() |> String.replace_prefix("application/", "")
    if normalized == String.downcase(expected), do: :ok, else: {:error, :invalid_typ}
  end

  defp typ(_header, _expected), do: {:error, :invalid_typ}

  # ---- keys

  defp signature(token, alg, kid, keys) do
    case candidates(keys, alg, kid) do
      [] ->
        {:error, :no_key}

      candidates ->
        if Enum.any?(candidates, &Backend.verify(token, &1, alg)),
          do: :ok,
          else: {:error, :bad_signature}
    end
  end

  # The keys that could have made this signature: of the algorithm's key
  # type, for signing, with this `alg` when the key names one, and with
  # the token's `kid` when it has one.
  defp candidates(%{"keys" => keys}, alg, kid), do: candidates(keys, alg, kid)

  defp candidates(keys, alg, kid) when is_list(keys) do
    Enum.filter(keys, fn jwk ->
      is_map(jwk) and (kid == nil or jwk["kid"] == kid) and jwk["use"] in [nil, "sig"] and
        jwk["alg"] in [nil, alg] and is_nil(jwk["d"]) and key_type(jwk) == key_type(alg) and
        strong?(jwk)
    end)
  end

  defp candidates(_keys, _alg, _kid), do: []

  defp key_type("RS256"), do: :rsa
  defp key_type("PS256"), do: :rsa
  defp key_type("ES256"), do: :p256
  defp key_type("ES384"), do: :p384

  defp key_type(%{"kty" => "RSA", "n" => n, "e" => e}) when is_binary(n) and is_binary(e),
    do: :rsa

  defp key_type(%{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y})
       when is_binary(x) and is_binary(y), do: :p256

  defp key_type(%{"kty" => "EC", "crv" => "P-384", "x" => x, "y" => y})
       when is_binary(x) and is_binary(y), do: :p384

  defp key_type(_other), do: nil

  defp strong?(%{"kty" => "RSA", "n" => n}) do
    case Base.url_decode64(n, padding: false) do
      {:ok, bytes} -> byte_size(String.trim_leading(bytes, <<0>>)) >= @min_rsa_bytes
      :error -> false
    end
  end

  defp strong?(_jwk), do: true

  # ---- claims

  defp required(claims, names) do
    case Enum.find(names, &(not Map.has_key?(claims, &1))) do
      nil -> :ok
      name -> {:error, {:missing_claim, name}}
    end
  end

  defp times(claims, now, opts) do
    leeway = Keyword.get(opts, :leeway, @leeway)

    cond do
      not numeric?(claims, ["exp", "nbf", "iat"]) -> {:error, :malformed}
      is_number(claims["exp"]) and now - leeway >= claims["exp"] -> {:error, :expired}
      is_number(claims["nbf"]) and now + leeway < claims["nbf"] -> {:error, :not_yet_valid}
      is_number(claims["iat"]) and now + leeway < claims["iat"] -> {:error, :issued_in_future}
      true -> :ok
    end
  end

  defp numeric?(claims, names),
    do: Enum.all?(names, &(not Map.has_key?(claims, &1) or is_number(claims[&1])))

  defp issuer(_claims, nil), do: :ok
  defp issuer(%{"iss" => iss}, iss) when is_binary(iss), do: :ok
  defp issuer(_claims, _expected), do: {:error, :invalid_issuer}

  defp audience(claims, nil), do: {:ok, claims}

  defp audience(claims, expected) do
    accepted = List.wrap(expected)

    if claims["aud"] |> audiences() |> Enum.any?(&(&1 in accepted)),
      do: {:ok, claims},
      else: {:error, :invalid_audience}
  end

  defp audiences(aud) when is_binary(aud), do: [aud]
  defp audiences(auds) when is_list(auds), do: Enum.filter(auds, &is_binary/1)
  defp audiences(_aud), do: []
end

if Code.ensure_loaded?(JOSE) do
  defmodule Sake.Auth.JWT.JOSE do
    @moduledoc false
    # The signing and verification `Sake.Auth.JWT` delegates to `jose`. The
    # caller has already chosen the one algorithm to allow and a key of its
    # type; this only does the cryptography.

    @spec verify(String.t(), map(), String.t()) :: boolean()
    def verify(token, jwk, alg) do
      match?({true, _payload, _jws}, JOSE.JWS.verify_strict(JOSE.JWK.from_map(jwk), [alg], token))
    rescue
      _ -> false
    catch
      _kind, _reason -> false
    end

    @spec sign(binary(), JOSE.JWK.t(), map()) :: String.t()
    def sign(payload, key, header) do
      {_, token} = key |> JOSE.JWS.sign(payload, header) |> JOSE.JWS.compact()
      token
    end

    @spec private_key(String.t()) :: {:ok, JOSE.JWK.t()} | :error
    def private_key(pem) do
      with %JOSE.JWK{} = key <- JOSE.JWK.from_pem(pem),
           {_, %{"d" => _}} <- JOSE.JWK.to_map(key) do
        {:ok, key}
      else
        _ -> :error
      end
    rescue
      _ -> :error
    end

    @spec public_jwk(JOSE.JWK.t()) :: map()
    def public_jwk(key) do
      {_, map} = JOSE.JWK.to_public_map(key)
      map
    end
  end
else
  defmodule Sake.Auth.JWT.JOSE do
    @moduledoc false
    # Without `jose`, nothing can be signed or verified. Sake never gets
    # here: everything that needs a signature checks
    # `Sake.Auth.JWT.available?/0` first, or refuses to start.

    def verify(_token, _jwk, _alg), do: false
    def sign(_payload, _key, _header), do: missing!()
    def private_key(_pem), do: missing!()
    def public_jwk(_key), do: missing!()

    defp missing!, do: Sake.Auth.JWT.require!("Signing a JWT")
  end
end
