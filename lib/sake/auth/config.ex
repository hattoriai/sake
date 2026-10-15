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

  @doc "All scopes the configured servers declare, with descriptions."
  @spec scopes(t()) :: [{String.t(), String.t()}]
  def scopes(%__MODULE__{servers: servers}),
    do: servers |> Enum.flat_map(& &1.__sake__(:scopes)) |> Enum.uniq_by(&elem(&1, 0))

  def authorize_url(c), do: c.issuer <> c.oauth_path <> "/authorize"
  def token_url(c), do: c.issuer <> c.oauth_path <> "/token"
  def register_url(c), do: c.issuer <> c.oauth_path <> "/register"
  def revoke_url(c), do: c.issuer <> c.oauth_path <> "/revoke"
end
