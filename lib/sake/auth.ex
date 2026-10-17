defmodule Sake.Auth do
  @moduledoc """
  Authorization for a Sake endpoint: the host app is the OAuth 2.1
  authorization server, and the endpoint is the resource server.

  Configure it on the `Sake` child (see `Sake.child_spec/1`) and mount the
  routes with `Sake.Router` (Phoenix) or `Sake.Auth.RouterPlug` (Plug).
  An endpoint whose tokens come from another authorization server is
  `Sake.Auth.External`'s instead.

  ## The public API

  These modules are for host code; every other `Sake.Auth` module is
  Sake's own and may change in any release:

    * `Sake.Auth` — the configuration, a person's grants, pruning.
    * `Sake.Auth.Config` — the `auth:` options.
    * `Sake.Auth.Subject` — the behaviour of the host's subject module.
    * `Sake.Auth.Consent` and `Sake.Auth.Consent.Default` — the consent
      and error pages.
    * `Sake.Auth.Store`, `Sake.Auth.Store.ETS`, `Sake.Auth.Store.Ecto`
      and `Sake.Auth.Migration` — where clients, codes, tokens and
      consents live; `Sake.Auth.Code` is the code a store keeps.
    * `Sake.Auth.External` — an endpoint on another authorization server.
    * `Sake.Auth.TokenRecord` — the token of a request, in `ctx.token`.
    * `Sake.Auth.Client` and `Sake.Auth.Clients` — the registered clients.
    * `Sake.Auth.TrustedIssuer` — the issuers of JWT grants.
    * `Sake.Auth.Challenge` — a `WWW-Authenticate` challenge.
    * `Sake.Auth.WellKnown`, `Sake.Auth.Authorize` and
      `Sake.Auth.RouterPlug` — the endpoints a Plug host mounts itself.
    * `Sake.Client.Auth`, `Sake.Client.Auth.Browser`,
      `Sake.Client.Auth.Headless` and `Sake.Client.Auth.Store` — the
      client's `auth:` options.

  Calls run one way: the rest of Sake calls these modules (and the
  functions marked `@doc false` that say who calls them), and nothing in
  `Sake.Auth` or `Sake.Client.Auth` calls the rest of Sake.
  """

  alias Sake.Auth.{Bearer, Config, DPoP, JWT, Tokens}

  @spec config() :: Config.t()
  def config do
    configured() || raise "Sake authorization is not configured: start {Sake, auth: [...]}"
  end

  @doc false
  # The configuration, or nil when Sake runs without its own
  # authorization server (no auth at all, or external ones only).
  # `Sake.Test` calls it.
  @spec configured() :: Config.t() | nil
  def configured, do: :persistent_term.get({__MODULE__, :config}, nil)

  @doc false
  # The authorization extensions whose grants the authorization server
  # offers, for the capabilities of an endpoint it protects
  # (`Sake.Server.Dispatch` calls it). They follow its metadata: client
  # credentials when `grant_types_supported` lists them,
  # enterprise-managed authorization when a trusted issuer issues
  # ID-JAGs. A workload's JWT grant has no extension to declare.
  @spec extensions(Config.t()) :: [:client_credentials | :enterprise]
  def extensions(config) do
    for {true, name} <- [
          {"client_credentials" in Sake.Auth.Token.grant_types(config), :client_credentials},
          {Enum.any?(config.trusted_issuers, &(&1.profile == :id_jag)), :enterprise}
        ],
        do: name
  end

  @doc false
  # Checks the access token of a request to an endpoint with `auth:`
  # (`Sake.Plug` calls it): `{:ok, conn}` with the token, its scopes and
  # its principal assigned, or `{:error, challenge}` for the 401.
  @spec authenticate(Plug.Conn.t(), map()) ::
          {:ok, Plug.Conn.t()} | {:error, Sake.Auth.Challenge.t()}
  def authenticate(conn, plug_opts), do: Bearer.check(conn, plug_opts)

  @doc false
  # The 403 challenge for a component the token's scopes do not cover
  # (`Sake.Plug` calls it).
  @spec insufficient_scope(Plug.Conn.t(), [String.t()]) :: Sake.Auth.Challenge.t()
  def insufficient_scope(conn, scopes), do: Bearer.insufficient_scope(conn, scopes)

  @doc false
  # Issues an access token in the store, for a test request (`Sake.Test`
  # calls it). `jkt` binds it to a DPoP key.
  @spec issue_access_token(Config.t(), map()) :: String.t()
  def issue_access_token(config, attrs) do
    {token, _record} = Tokens.issue_access(config, attrs)
    token
  end

  @doc false
  # A new DPoP key as PEM, and its thumbprint, for a test token bound to
  # it (`Sake.Test` calls it).
  @spec dpop_key() :: {String.t(), String.t()}
  def dpop_key do
    pem = DPoP.generate_key()
    {:ok, key} = JWT.private_key(pem)
    {pem, key |> JWT.public_jwk() |> JWT.thumbprint()}
  end

  @doc false
  def store(%Config{store: {module, _}, store_state: state}), do: {module, state}

  @doc "The active grants of a person: one entry per client, for a settings page."
  @spec list_grants(Config.t(), String.t()) :: [map()]
  def list_grants(config, subject_id) do
    {module, state} = store(config)
    now = DateTime.utc_now()

    module.tokens_for_subject(state, subject_id)
    |> Enum.filter(
      &(&1.kind == :refresh and Sake.Auth.Tokens.valid?(&1, now) and &1.used_at == nil)
    )
    |> Enum.group_by(& &1.client_id)
    |> Enum.map(fn {client_id, tokens} ->
      client =
        case module.get_client(state, client_id) do
          {:ok, c} -> c
          :error -> nil
        end

      %{
        client_id: client_id,
        client_name: client && client.name,
        scopes: tokens |> Enum.flat_map(& &1.scopes) |> Enum.uniq(),
        resource: hd(tokens).resource,
        granted_at: tokens |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime),
        last_used_at: nil,
        family_ids: Enum.map(tokens, & &1.family_id)
      }
    end)
  end

  @doc "Revokes every token of a client for a person, and forgets every consent of that client for the person."
  @spec revoke_grant(Config.t(), String.t(), String.t()) :: :ok
  def revoke_grant(config, subject_id, client_id) do
    {module, state} = store(config)

    module.tokens_for_subject(state, subject_id)
    |> Enum.filter(&(&1.client_id == client_id))
    |> Enum.map(& &1.family_id)
    |> Enum.uniq()
    |> Enum.each(&module.revoke_family(state, &1))

    module.delete_consent(state, subject_id, client_id, :all)
  end

  @doc """
  Deletes expired codes and tokens, the remembered consents older than
  the refresh token lifetime that no live token family still uses, and
  the dynamically registered clients that, `unused_client_ttl` seconds
  (a day by default) after registering, hold no live token, consent or
  code. Schedule it (a cron job, Oban, or a periodic task).
  """
  @spec prune(Config.t()) :: :ok
  def prune(config) do
    {module, state} = store(config)
    now = DateTime.utc_now()

    module.prune(state, now, %{
      consents: DateTime.add(now, -config.refresh_token_ttl),
      unused_clients: DateTime.add(now, -config.unused_client_ttl)
    })
  end
end
