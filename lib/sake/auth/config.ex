defmodule Sake.Auth.Config do
  @moduledoc """
  The authorization configuration given to `{Sake, auth: [...]}`.

  `secret` is the Sake secret (`secret_key_base:` of the `Sake` child,
  else `config :sake, :secret_key_base`), which `Sake` reads once when
  it starts and puts here: it signs the consent form's request and the
  DPoP nonces.

  `device:` turns on the device authorization grant (RFC 8628), for
  clients with no browser: `true`, or `[expires_in: seconds, interval:
  seconds]` (how long a device code lasts, 600 by default, and how long
  a client waits between two polls of the token endpoint, 5 by
  default). It is off by default: the verification page has to be
  mounted inside the host's signed-in pipeline first (see
  `Sake.Auth.DeviceVerification`). It needs the Sake secret.

  `par:` turns on pushed authorization requests (RFC 9126): `true`, or
  `[required: boolean, expires_in: seconds]`. A client then pushes its
  authorization request to `POST {oauth_path}/par`, authenticated as at
  the token endpoint, and sends the person to the authorize endpoint
  with the `request_uri` it got back, good once, for `expires_in`
  seconds (60 by default). `required: true` refuses every authorization
  request that was not pushed, as a client registered with
  `require_pushed_authorization_requests` has its own refused. It is off
  by default, and the metadata then says nothing about it.

  `acr_values:` lists the authentication context classes the host's
  login can sign a person in with (`["pwd", "mfa"]`, say: the `acr`
  values `c:Sake.Auth.Subject.authentication/1` returns), for the
  metadata's `acr_values_supported` (RFC 9470). An authorization
  request's `acr_values` are then narrowed to those, and a request that
  names none of them is refused with `invalid_request`. Without it,
  the metadata says nothing and any `acr_values` are taken as they come.

  `openid:` turns on OpenID Connect: `true`, or `[id_token_ttl:
  seconds]` (how long an ID token lasts, the access token's lifetime by
  default). The token endpoint then answers a grant whose scopes include
  `openid` with an `id_token` as well, `GET {oauth_path}/jwks` publishes
  the signing keys, `{oauth_path}/userinfo` returns the person's claims,
  and `/.well-known/openid-configuration` describes it all. The
  `openid`, `profile` and `email` scopes are the authorization server's
  own: no server declares them. It is off by default, and needs the
  `jose` package and `signing_keys:`.

  `signing_keys:` are the keys ID tokens are signed with: a list of
  `[kid: "2026-10", pem: pem]` (or maps with those keys), each a PEM
  private key, RSA (2048 bits or more, signing RS256), P-256 (ES256) or
  P-384 (ES384), with a `kid` of its own. The first one signs, and all
  of them are published at the JWKS endpoint, so a key is rotated by
  putting the new one first, and dropped once the ID tokens it signed
  have expired. Only with `openid:`.
  """

  @type t :: %__MODULE__{}
  defstruct subject: nil,
            store: {Sake.Auth.Store.ETS, []},
            store_state: nil,
            issuer: nil,
            resources: nil,
            access_token_ttl: 3_600,
            refresh_token_ttl: 30 * 24 * 3_600,
            unused_client_ttl: 24 * 3_600,
            cimd: [policy: :allow_all],
            dcr: true,
            remember_consent: true,
            consent: Sake.Auth.Consent.Default,
            servers: [],
            trusted_issuers: [],
            max_assertion_lifetime: 300,
            allow_insecure: false,
            oauth_path: "/oauth",
            dpop: true,
            device: false,
            par: false,
            acr_values: nil,
            openid: false,
            signing_keys: [],
            name: nil,
            secret: nil

  @spec new(keyword()) :: t()
  def new(opts) do
    config = struct!(__MODULE__, opts)
    config.subject || raise ArgumentError, "Sake auth needs a subject: module"
    config.issuer || raise ArgumentError, "Sake auth needs an issuer: URL"
    uri = URI.parse(config.issuer)

    unless uri.scheme == "https" or (config.allow_insecure and uri.scheme == "http"),
      do:
        raise(
          ArgumentError,
          "the issuer must be an https URL (or allow_insecure: true in development)"
        )

    unless is_integer(config.max_assertion_lifetime) and config.max_assertion_lifetime > 0,
      do: raise(ArgumentError, "max_assertion_lifetime: is a positive number of seconds")

    {module, store_opts} = config.store

    %{
      config
      | issuer: String.trim_trailing(config.issuer, "/"),
        trusted_issuers: trusted_issuers(config),
        dpop: dpop_option(config.dpop, config.secret),
        device: device_option(config.device, config.secret),
        par: par_option(config.par),
        acr_values: acr_values_option(config.acr_values),
        openid: openid_option(config.openid, config.access_token_ttl),
        signing_keys: Sake.Auth.SigningKeys.new(config.signing_keys, config.openid != false),
        store_state: module.init(store_opts),
        name: config.name || uri.host
    }
  end

  # JWT grants need jose to verify them, and the subject module's
  # `assertion_principal/2` to say whom they stand for: a host that trusts
  # an issuer without either finds out when it starts, not at the first
  # grant.
  defp trusted_issuers(%__MODULE__{trusted_issuers: []}), do: []

  defp trusted_issuers(%__MODULE__{trusted_issuers: issuers, subject: subject}) do
    Sake.Auth.JWT.require!("trusted_issuers:")
    Code.ensure_loaded(subject)

    unless function_exported?(subject, :assertion_principal, 2),
      do:
        raise(
          ArgumentError,
          "trusted_issuers: needs the subject module to define assertion_principal/2"
        )

    Enum.map(issuers, &Sake.Auth.TrustedIssuer.new/1)
  end

  @doc false
  # DPoP needs jose to check proofs. By default it is on when jose is
  # there, and quietly off when not (the metadata then does not offer it);
  # a host that asks for it by name, nonces or `required:` and all, is
  # told at start. `Sake.Auth.External` takes the same option. Nonces are
  # made with the configuration's `secret`.
  @spec dpop_option(term(), binary() | nil) :: false | %{nonce: boolean(), required: boolean()}
  def dpop_option(false, _secret), do: false

  def dpop_option(true, _secret),
    do: if(Sake.Auth.JWT.available?(), do: %{nonce: false, required: false}, else: false)

  def dpop_option(opts, secret) when is_list(opts) do
    Sake.Auth.JWT.require!("dpop:")
    nonce = Keyword.get(opts, :nonce, false)
    required = Keyword.get(opts, :required, false)

    unless is_boolean(nonce) and is_boolean(required) and
             Keyword.keys(opts) -- [:nonce, :required] == [],
           do:
             raise(
               ArgumentError,
               "dpop: takes [nonce: boolean, required: boolean], got #{inspect(opts)}"
             )

    if nonce and secret == nil,
      do:
        raise(
          ArgumentError,
          "dpop: [nonce: true] needs the Sake secret: start {Sake, secret_key_base: ...}"
        )

    %{nonce: nonce, required: required}
  end

  def dpop_option(other, _secret),
    do:
      raise(
        ArgumentError,
        "dpop: must be true, false or [nonce: boolean, required: boolean], got #{inspect(other)}"
      )

  @device_defaults %{expires_in: 600, interval: 5}

  # The device grant: false, or its expiry and polling interval in
  # seconds. The verification page signs its forms with the secret.
  defp device_option(false, _secret), do: false
  defp device_option(true, secret), do: device_option([], secret)

  defp device_option(opts, secret) when is_list(opts) do
    unless Keyword.keys(opts) -- [:expires_in, :interval] == [] and
             Enum.all?(opts, fn {_k, v} -> is_integer(v) and v > 0 end),
           do:
             raise(
               ArgumentError,
               "device: takes [expires_in: seconds, interval: seconds], got #{inspect(opts)}"
             )

    if secret == nil,
      do:
        raise(
          ArgumentError,
          "device: needs the Sake secret: start {Sake, secret_key_base: ...}"
        )

    Map.merge(@device_defaults, Map.new(opts))
  end

  defp device_option(other, _secret),
    do:
      raise(
        ArgumentError,
        "device: must be true, false or [expires_in: seconds, interval: seconds], got #{inspect(other)}"
      )

  @par_defaults %{required: false, expires_in: 60}

  # Pushed authorization requests: false, or whether every authorization
  # request must be pushed, and how long a request_uri lasts.
  defp par_option(false), do: false
  defp par_option(true), do: par_option([])

  defp par_option(opts) when is_list(opts) do
    par = Map.merge(@par_defaults, Map.new(opts))

    unless Keyword.keys(opts) -- [:required, :expires_in] == [] and is_boolean(par.required) and
             is_integer(par.expires_in) and par.expires_in > 0,
           do:
             raise(
               ArgumentError,
               "par: takes [required: boolean, expires_in: seconds], got #{inspect(opts)}"
             )

    par
  end

  defp par_option(other),
    do:
      raise(
        ArgumentError,
        "par: must be true, false or [required: boolean, expires_in: seconds], got #{inspect(other)}"
      )

  # The acr values the host's login offers: nil, or a list of strings.
  defp acr_values_option(nil), do: nil

  defp acr_values_option(values) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_binary(&1) and &1 != "" and not String.contains?(&1, " "))),
      do: Enum.uniq(values),
      else: bad_acr_values!(values)
  end

  defp acr_values_option(other), do: bad_acr_values!(other)

  defp bad_acr_values!(values),
    do:
      raise(
        ArgumentError,
        "acr_values: must be a non-empty list of strings without spaces, got #{inspect(values)}"
      )

  # OpenID Connect: false, or how long an ID token lasts. It signs with
  # jose, which the host is told about at start.
  defp openid_option(false, _ttl), do: false
  defp openid_option(true, ttl), do: openid_option([], ttl)

  defp openid_option(opts, ttl) when is_list(opts) do
    Sake.Auth.JWT.require!("openid:")
    openid = Map.merge(%{id_token_ttl: ttl}, Map.new(opts))

    unless Keyword.keys(opts) -- [:id_token_ttl] == [] and is_integer(openid.id_token_ttl) and
             openid.id_token_ttl > 0,
           do:
             raise(
               ArgumentError,
               "openid: takes [id_token_ttl: seconds], got #{inspect(opts)}"
             )

    openid
  end

  defp openid_option(other, _ttl),
    do:
      raise(
        ArgumentError,
        "openid: must be true, false or [id_token_ttl: seconds], got #{inspect(other)}"
      )

  @doc """
  Whether `client`'s authorization requests must be pushed: with `par:
  [required: true]`, or a client registered with
  `require_pushed_authorization_requests`. Never without `par:`.
  """
  @spec par_required?(t(), Sake.Auth.Client.t()) :: boolean()
  def par_required?(%{par: false}, _client), do: false

  def par_required?(%{par: %{required: required}}, client),
    do: required or client.require_pushed_authorization_requests == true

  @doc "Whether every access token must be DPoP-bound (`dpop: [required: true]`)."
  @spec dpop_required?(t() | Sake.Auth.External.t()) :: boolean()
  def dpop_required?(%{dpop: %{required: true}}), do: true
  def dpop_required?(_config), do: false

  @doc "All scopes the configured servers declare, with descriptions."
  @spec scopes(t() | Sake.Auth.External.t()) :: [{String.t(), String.t()}]
  def scopes(%{servers: servers}),
    do: servers |> Enum.flat_map(& &1.__sake__(:scopes)) |> Enum.uniq_by(&elem(&1, 0))

  @openid_scopes [
    {"openid", "Know who you are"},
    {"profile", "See your name and profile"},
    {"email", "See your email address"}
  ]

  @doc """
  The OpenID Connect scopes, with descriptions, with `openid:`: the
  authorization server's own, which no server declares; none without it.
  """
  @spec openid_scopes(t()) :: [{String.t(), String.t()}]
  def openid_scopes(%__MODULE__{openid: false}), do: []
  def openid_scopes(%__MODULE__{}), do: @openid_scopes

  @doc """
  Every scope an authorization request may ask for: the servers' (see
  `scopes/1`), then the OpenID Connect ones (see `openid_scopes/1`).
  """
  @spec request_scopes(t()) :: [{String.t(), String.t()}]
  def request_scopes(config),
    do: Enum.uniq_by(scopes(config) ++ openid_scopes(config), &elem(&1, 0))

  def authorize_url(c), do: c.issuer <> c.oauth_path <> "/authorize"
  def token_url(c), do: c.issuer <> c.oauth_path <> "/token"
  def register_url(c), do: c.issuer <> c.oauth_path <> "/register"
  def revoke_url(c), do: c.issuer <> c.oauth_path <> "/revoke"
  def device_authorization_url(c), do: c.issuer <> c.oauth_path <> "/device_authorization"
  def device_url(c), do: c.issuer <> c.oauth_path <> "/device"
  def par_url(c), do: c.issuer <> c.oauth_path <> "/par"
  def jwks_url(c), do: c.issuer <> c.oauth_path <> "/jwks"
  def userinfo_url(c), do: c.issuer <> c.oauth_path <> "/userinfo"
end
