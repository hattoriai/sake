defmodule Sake.Auth do
  @moduledoc """
  Authorization for a Sake endpoint: the host app is the OAuth 2.1
  authorization server, and the endpoint is the resource server.

  Configure it on the `Sake` child (see `Sake.child_spec/1`) and mount the
  routes with `Sake.Router` (Phoenix) or `Sake.Auth.RouterPlug` (Plug).
  An endpoint whose tokens come from another authorization server is
  `Sake.Auth.External`'s instead.
  """

  alias Sake.Auth.Config

  @spec config() :: Config.t()
  def config do
    configured() || raise "Sake authorization is not configured: start {Sake, auth: [...]}"
  end

  @doc false
  # The configuration, or nil when Sake runs without its own
  # authorization server (no auth at all, or external ones only).
  @spec configured() :: Config.t() | nil
  def configured, do: :persistent_term.get({Sake, :auth}, nil)

  @doc """
  The identifier of an authorization extension: `:client_credentials`
  (`io.modelcontextprotocol/oauth-client-credentials`) or `:enterprise`
  (`io.modelcontextprotocol/enterprise-managed-authorization`).
  """
  @spec extension(:client_credentials | :enterprise) :: String.t()
  def extension(:client_credentials), do: "io.modelcontextprotocol/oauth-client-credentials"
  def extension(:enterprise), do: "io.modelcontextprotocol/enterprise-managed-authorization"

  @doc false
  # The authorization extensions whose grants the authorization server
  # offers, for the capabilities of an endpoint it protects. They follow
  # its metadata: client credentials when `grant_types_supported` lists
  # them, enterprise-managed authorization when a trusted issuer issues
  # ID-JAGs. A workload's JWT grant has no extension to declare.
  @spec extensions(Config.t()) :: map()
  def extensions(config) do
    %{}
    |> put_extension(
      "client_credentials" in Sake.Auth.Token.grant_types(config),
      :client_credentials
    )
    |> put_extension(Enum.any?(config.trusted_issuers, &(&1.profile == :id_jag)), :enterprise)
  end

  defp put_extension(ext, true, name), do: Map.put(ext, extension(name), %{})
  defp put_extension(ext, false, _name), do: ext

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
