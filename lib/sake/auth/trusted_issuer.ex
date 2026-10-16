defmodule Sake.Auth.TrustedIssuer do
  @moduledoc """
  An issuer whose signed JWTs the token endpoint accepts as authorization
  grants (`urn:ietf:params:oauth:grant-type:jwt-bearer`, RFC 7523). Give
  them to `{Sake, auth: [trusted_issuers: [...]]}`:

      trusted_issuers: [
        [issuer: "https://acme.okta.com", clients: ["rc_..."]],
        [
          issuer: "https://token.actions.githubusercontent.com",
          profile: :workload,
          audiences: ["https://mcp.example.com"],
          clients: ["rc_..."]
        ]
      ]

  Options:

    * `:issuer` (required) — the `iss` its JWTs carry, compared exactly.
    * `:profile` — `:id_jag` (the default), an enterprise identity
      provider issuing Identity Assertion JWT Authorization Grants
      (`typ` `oauth-id-jag+jwt`, with `jti`, `iat`, `sub` and a
      `client_id` that must be the authenticated client); or
      `:workload`, a platform issuing workload identity tokens (a CI
      system, a cloud, Kubernetes), whose JWTs need only `sub` and
      `exp`.
    * `:clients` (required) — the client IDs that may present its
      grants, or `:any`. A client must also have the JWT bearer grant
      type among its `grant_types`.
    * `:jwks` — its public keys, a JWK Set map; or `:jwks_uri`, where to
      fetch them. Without either, the `jwks_uri` of its OpenID Connect
      or RFC 8414 metadata is used.
    * `:audiences` — the `aud` values accepted; by default this
      authorization server's issuer and its token endpoint URL.
    * `:scopes` — the most its grants may ask for; by default anything
      the servers declare.
    * `:max_lifetime` — the longest, in seconds, a grant may still be
      valid when it is presented: one whose `exp` is further ahead is
      refused. By default 300 for `:id_jag` (an identity provider issues
      them for minutes) and 3600 for `:workload` (cloud and Kubernetes
      identity tokens commonly live an hour). It also bounds how long a
      workload token without a `jti`, which cannot be made single use,
      can be presented again.

  The person or workload a grant stands for is the subject module's
  `c:Sake.Auth.Subject.assertion_principal/2`; without it, every grant
  is refused.
  """

  @type t :: %__MODULE__{
          issuer: String.t(),
          profile: :id_jag | :workload,
          clients: [String.t()] | :any,
          jwks: map() | nil,
          jwks_uri: String.t() | nil,
          audiences: [String.t()] | nil,
          scopes: [String.t()] | nil,
          max_lifetime: pos_integer()
        }

  @enforce_keys [:issuer, :clients]
  defstruct [
    :issuer,
    :clients,
    :jwks,
    :jwks_uri,
    :audiences,
    :scopes,
    :max_lifetime,
    profile: :id_jag
  ]

  @doc false
  @spec new(keyword() | map()) :: t()
  def new(opts) do
    issuer = struct!(__MODULE__, opts)

    cond do
      not is_binary(issuer.issuer) ->
        raise ArgumentError, "a trusted issuer needs an issuer: URL"

      issuer.profile not in [:id_jag, :workload] ->
        raise ArgumentError, "a trusted issuer's profile: is :id_jag or :workload"

      not (issuer.clients == :any or (is_list(issuer.clients) and issuer.clients != [])) ->
        raise ArgumentError, "a trusted issuer needs clients: (a list of client IDs, or :any)"

      true ->
        %{issuer | max_lifetime: max_lifetime(issuer.max_lifetime, issuer.profile)}
    end
  end

  defp max_lifetime(nil, :id_jag), do: 300
  defp max_lifetime(nil, :workload), do: 3_600
  defp max_lifetime(seconds, _profile) when is_integer(seconds) and seconds > 0, do: seconds

  defp max_lifetime(_other, _profile),
    do: raise(ArgumentError, "a trusted issuer's max_lifetime: is a positive number of seconds")
end
