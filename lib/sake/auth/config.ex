defmodule Sake.Auth.Config do
  @moduledoc "The authorization configuration given to `{Sake, auth: [...]}`."

  @type t :: %__MODULE__{}
  defstruct subject: nil,
            store: {Sake.Auth.Store.ETS, []},
            store_state: nil,
            issuer: nil,
            resources: nil,
            access_token_ttl: 3_600,
            refresh_token_ttl: 30 * 24 * 3_600,
            cimd: [policy: :allow_all],
            dcr: true,
            remember_consent: true,
            consent: Sake.Auth.Consent.Default,
            servers: [],
            trusted_issuers: [],
            allow_insecure: false,
            oauth_path: "/oauth",
            dpop: true,
            name: nil

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

    {module, store_opts} = config.store

    %{
      config
      | issuer: String.trim_trailing(config.issuer, "/"),
        trusted_issuers: trusted_issuers(config),
        dpop: dpop(config.dpop),
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

  # DPoP needs jose to check proofs. By default it is on when jose is
  # there, and quietly off when not (the metadata then does not offer it);
  # a host that asks for it by name, nonces or `required:` and all, is
  # told at start.
  defp dpop(false), do: false

  defp dpop(true),
    do: if(Sake.Auth.JWT.available?(), do: %{nonce: false, required: false}, else: false)

  defp dpop(opts) when is_list(opts) do
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

    if nonce and Sake.Secret.configured() == nil,
      do:
        raise(
          ArgumentError,
          "dpop: [nonce: true] needs the Sake secret: start {Sake, secret_key_base: ...}"
        )

    %{nonce: nonce, required: required}
  end

  defp dpop(other),
    do:
      raise(
        ArgumentError,
        "dpop: must be true, false or [nonce: boolean, required: boolean], got #{inspect(other)}"
      )

  @doc "Whether every access token must be DPoP-bound (`dpop: [required: true]`)."
  @spec dpop_required?(t()) :: boolean()
  def dpop_required?(%__MODULE__{dpop: %{required: true}}), do: true
  def dpop_required?(_config), do: false

  @doc "All scopes the configured servers declare, with descriptions."
  @spec scopes(t()) :: [{String.t(), String.t()}]
  def scopes(%__MODULE__{servers: servers}),
    do: servers |> Enum.flat_map(& &1.__sake__(:scopes)) |> Enum.uniq_by(&elem(&1, 0))

  def authorize_url(c), do: c.issuer <> c.oauth_path <> "/authorize"
  def token_url(c), do: c.issuer <> c.oauth_path <> "/token"
  def register_url(c), do: c.issuer <> c.oauth_path <> "/register"
  def revoke_url(c), do: c.issuer <> c.oauth_path <> "/revoke"
end
