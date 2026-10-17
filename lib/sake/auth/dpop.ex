defmodule Sake.Auth.DPoP do
  @moduledoc false
  # DPoP (RFC 9449): a token bound to a key the client holds, and the
  # proof JWTs that show it still holds it, one per HTTP request. The
  # client's side makes proofs; the authorization server's and the
  # resource server's sides check them.
  #
  # A proof carries its own public key in its header, and is verified
  # with that key: on its own that shows only that whoever sent it holds
  # *some* key. What makes it mean something is the thumbprint (RFC 7638)
  # of that key, which the token endpoint binds the token to (`cnf.jkt`)
  # and the resource server compares with the token's binding. Each proof
  # is also tied to one request (`htm`, `htu`), one time (`iat`, plus a
  # server nonce when the server asks for one), one access token (`ath`)
  # and is accepted once (`jti`, through `Sake.Auth.Replay`).
  #
  # The signatures are `jose`'s, through `Sake.Auth.JWT`: without it a
  # client sends no proofs and a server neither binds nor accepts bound
  # tokens.

  import Plug.Conn, only: [get_req_header: 2, put_resp_header: 3]

  alias Sake.Auth.{JWT, Replay}

  @typ "dpop+jwt"

  # How old a proof may be. A proof is replayable for as long as it is
  # accepted, so its `jti` is kept that long; a server nonce shortens the
  # window to the nonce's own lifetime.
  @max_age 300
  @leeway 30

  # A proof is a few hundred bytes (an RSA key in its header makes it
  # larger); one beyond this is refused before it is decoded.
  @max_size 8_192

  # A nonce is good for the period it was made in and the next one.
  @nonce_period 300

  @doc "Whether DPoP is possible at all: proofs need `jose`."
  @spec available?() :: boolean()
  def available?, do: JWT.available?()

  @doc "The algorithms a proof may be signed with."
  @spec algs() :: [String.t()]
  def algs, do: JWT.algs()

  # ---- the client's side

  @doc "A new P-256 private key, as PEM (PKCS #8): ES256, the algorithm every DPoP server supports."
  @spec generate_key() :: String.t()
  def generate_key do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
  end

  @doc """
  A proof for one request: `htm` the method, `htu` the URL (its query and
  fragment are left out). Options: `:access_token` (adds its `ath` hash,
  for a request to a resource server) and `:nonce` (the server's latest).
  """
  @spec proof(JWT.key(), String.t(), String.t(), keyword()) :: String.t()
  def proof(key, htm, htu, opts \\ []) do
    claims =
      %{
        "jti" => 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false),
        "htm" => htm,
        "htu" => htu(htu),
        "iat" => System.system_time(:second)
      }
      |> put_present("ath", opts[:access_token] && ath(opts[:access_token]))
      |> put_present("nonce", opts[:nonce])

    JWT.sign(claims, key, JWT.default_alg(key), %{"typ" => @typ, "jwk" => JWT.public_jwk(key)})
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc "The `ath` claim for an access token: its SHA-256 hash, base64url-encoded."
  @spec ath(String.t()) :: String.t()
  def ath(token), do: :sha256 |> :crypto.hash(token) |> Base.url_encode64(padding: false)

  @doc """
  The `htu` form of a URL (RFC 9449 §4.3): lowercase scheme and host, no
  default port, no query or fragment, and `/` for an empty path.
  """
  @spec htu(String.t()) :: String.t()
  def htu(url) do
    uri = URI.parse(url)
    scheme = String.downcase(uri.scheme || "")
    host = String.downcase(uri.host || "")
    host = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
    port = if uri.port in [nil, URI.default_port(scheme)], do: "", else: ":#{uri.port}"
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    "#{scheme}://#{host}#{port}#{path}"
  end

  # ---- the server's side

  @doc """
  The request's DPoP proof: `:none` without one, `{:ok, proof}`, or an
  error for several (RFC 9449 §4.3 allows exactly one). A compact JWS has
  no commas, so a header with one is several proofs joined.
  """
  @spec from_conn(Plug.Conn.t()) :: :none | {:ok, String.t()} | {:error, String.t(), String.t()}
  def from_conn(conn) do
    case get_req_header(conn, "dpop") do
      [] ->
        :none

      [proof] ->
        if String.contains?(proof, ","),
          do: invalid("Only one DPoP proof is allowed"),
          else: {:ok, proof}

      _several ->
        invalid("Only one DPoP proof is allowed")
    end
  end

  @doc """
  Checks a proof (RFC 9449 §4.3) and returns the thumbprint of its key.
  Options:

    * `:htm` — the request's method.
    * `:htu` — the URLs the request may have been made to (compared in
      `htu/1` form).
    * `:access_token` — the token sent with it, whose hash `ath` must be.
    * `:nonce` — the secret of the server's nonces, when it requires
      one; nil when it does not.
    * `:now` — the current time in seconds, for tests.

  Errors are `{:error, code, description}`, `code` being
  `invalid_dpop_proof` or `use_dpop_nonce`. A proof is only recorded as
  used once everything else passed: one refused for its nonce can be
  followed by a fresh one.
  """
  @spec verify(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t(), String.t()}
  def verify(proof, opts) do
    with {:ok, checked} <- check(proof, opts),
         :ok <- record(checked),
         do: {:ok, checked.jkt}
  end

  @typedoc "A proof that passed `check/2`, not recorded as used yet."
  @type checked :: %{jkt: String.t(), jti: String.t(), iat: integer()}

  @doc """
  Checks a proof as `verify/2` does, without recording it as used: for a
  caller that has more to check first (the token endpoint authenticates
  the client), and then calls `record/1`.
  """
  @spec check(String.t(), keyword()) :: {:ok, checked()} | {:error, String.t(), String.t()}
  def check(proof, opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with :ok <- size(proof),
         {:ok, header, claims} <- peek(proof),
         {:ok, jwk} <- jwk(header),
         :ok <- signature(proof, jwk, now),
         :ok <- request(claims, opts[:htm], opts[:htu]),
         :ok <- fresh(claims, now),
         :ok <- bound_to(claims, opts[:access_token]),
         :ok <- nonce(claims, opts[:nonce], now) do
      {:ok, %{jkt: JWT.thumbprint(jwk), jti: claims["jti"], iat: claims["iat"]}}
    end
  end

  @doc "Records a checked proof as used; refuses one already used."
  @spec record(checked()) :: :ok | {:error, String.t(), String.t()}
  def record(%{jkt: jkt, jti: jti, iat: iat}) do
    case Replay.once("dpop:" <> jkt, jti, iat + @max_age) do
      :ok -> :ok
      {:error, :replayed} -> invalid("The DPoP proof was already used")
    end
  end

  defp size(proof) when byte_size(proof) <= @max_size, do: :ok
  defp size(_proof), do: invalid("The DPoP proof is too large")

  defp peek(proof) do
    case JWT.peek(proof) do
      {:ok, header, claims} -> {:ok, header, claims}
      {:error, :malformed} -> invalid("The DPoP proof is not a JWT")
    end
  end

  # The key to verify with is the proof's own, and only a public one: a
  # private key in a header would be a client leaking it.
  defp jwk(%{"jwk" => %{"d" => _}}), do: invalid("The proof's jwk must be a public key")
  defp jwk(%{"jwk" => jwk}) when is_map(jwk), do: {:ok, jwk}
  defp jwk(_header), do: invalid("The DPoP proof has no jwk header")

  defp signature(proof, jwk, now) do
    case JWT.verify(proof, [jwk], typ: @typ, required: ~w(jti htm htu iat), now: now) do
      {:ok, _claims} -> :ok
      {:error, :invalid_typ} -> invalid("The proof's typ must be dpop+jwt")
      {:error, :unsupported_alg} -> invalid("The proof's alg is not supported")
      {:error, {:missing_claim, name}} -> invalid("The DPoP proof has no #{name}")
      {:error, :issued_in_future} -> invalid("The DPoP proof was issued in the future")
      {:error, _reason} -> invalid("The DPoP proof's signature does not verify")
    end
  end

  defp request(%{"jti" => jti, "htm" => htm, "htu" => htu}, method, urls)
       when is_binary(jti) and is_binary(htm) and is_binary(htu) do
    cond do
      htm != method ->
        invalid("The proof's htm does not match the request")

      htu(htu) not in Enum.map(urls, &htu/1) ->
        invalid("The proof's htu does not match the request")

      true ->
        :ok
    end
  end

  defp request(_claims, _method, _urls),
    do: invalid("The proof's jti, htm and htu must be strings")

  defp fresh(%{"iat" => iat}, now) when is_number(iat) do
    if iat >= now - @max_age - @leeway,
      do: :ok,
      else: invalid("The DPoP proof is too old")
  end

  defp fresh(_claims, _now), do: invalid("The proof's iat must be a number")

  defp bound_to(_claims, nil), do: :ok

  defp bound_to(%{"ath" => ath}, token) when is_binary(ath) do
    if Plug.Crypto.secure_compare(ath, ath(token)),
      do: :ok,
      else: invalid("The proof's ath does not match the access token")
  end

  defp bound_to(_claims, _token), do: invalid("The DPoP proof has no ath")

  defp nonce(_claims, nil, _now), do: :ok

  defp nonce(%{"nonce" => nonce}, secret, now) when is_binary(nonce) do
    if valid_nonce?(secret, nonce, now),
      do: :ok,
      else: {:error, "use_dpop_nonce", "The DPoP nonce is unknown or has expired"}
  end

  defp nonce(_claims, _secret, _now),
    do: {:error, "use_dpop_nonce", "This server requires a nonce in the DPoP proof"}

  defp invalid(description), do: {:error, "invalid_dpop_proof", description}

  # ---- nonces

  # A nonce is a MAC of the current period under the Sake secret: nothing
  # is stored, and every node with the same secret makes and accepts the
  # same ones, so a client sent to another node of a cluster is not sent
  # round in nonce challenges.

  @doc "The secret of the server's nonces when the configuration requires them, else nil."
  @spec nonce_secret(Sake.Auth.Config.t() | Sake.Auth.External.t()) :: binary() | nil
  def nonce_secret(%{dpop: %{nonce: true}, secret: secret}), do: secret
  def nonce_secret(_config), do: nil

  @doc """
  Adds the current nonce to a response, when the server requires them:
  to a challenge, and to every other answer too, so a client always
  holds the latest one (RFC 9449 §8.2 and §9).
  """
  @spec put_nonce(Plug.Conn.t(), Sake.Auth.Config.t() | Sake.Auth.External.t()) :: Plug.Conn.t()
  def put_nonce(conn, config) do
    case current_nonce(config) do
      nil -> conn
      nonce -> put_resp_header(conn, "dpop-nonce", nonce)
    end
  end

  @doc "The server's current nonce when the configuration requires them, else nil."
  @spec current_nonce(Sake.Auth.Config.t() | Sake.Auth.External.t()) :: String.t() | nil
  def current_nonce(config) do
    case nonce_secret(config) do
      nil -> nil
      secret -> nonce(secret)
    end
  end

  @doc "The server's current nonce."
  @spec nonce(binary(), integer()) :: String.t()
  def nonce(secret, now \\ System.system_time(:second)),
    do: period_nonce(secret, div(now, @nonce_period))

  @doc "Whether `nonce` is the current one or the one before it."
  @spec valid_nonce?(binary(), String.t(), integer()) :: boolean()
  def valid_nonce?(secret, nonce, now \\ System.system_time(:second)) do
    period = div(now, @nonce_period)

    Enum.any?(
      [period, period - 1],
      &Plug.Crypto.secure_compare(period_nonce(secret, &1), nonce)
    )
  end

  defp period_nonce(secret, period) do
    :hmac
    |> :crypto.mac(:sha256, secret, "sake dpop nonce " <> Integer.to_string(period))
    |> binary_part(0, 18)
    |> Base.url_encode64(padding: false)
  end
end
