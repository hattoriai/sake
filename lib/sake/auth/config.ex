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

  @doc "Whether every access token must be DPoP-bound (`dpop: [required: true]`)."
  @spec dpop_required?(t() | Sake.Auth.External.t()) :: boolean()
  def dpop_required?(%{dpop: %{required: true}}), do: true
  def dpop_required?(_config), do: false

  @doc "All scopes the configured servers declare, with descriptions."
  @spec scopes(t() | Sake.Auth.External.t()) :: [{String.t(), String.t()}]
  def scopes(%{servers: servers}),
    do: servers |> Enum.flat_map(& &1.__sake__(:scopes)) |> Enum.uniq_by(&elem(&1, 0))

  def authorize_url(c), do: c.issuer <> c.oauth_path <> "/authorize"
  def token_url(c), do: c.issuer <> c.oauth_path <> "/token"
  def register_url(c), do: c.issuer <> c.oauth_path <> "/register"
  def revoke_url(c), do: c.issuer <> c.oauth_path <> "/revoke"
  def device_authorization_url(c), do: c.issuer <> c.oauth_path <> "/device_authorization"
  def device_url(c), do: c.issuer <> c.oauth_path <> "/device"
end
