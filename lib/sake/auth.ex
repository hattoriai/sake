defmodule Sake.Auth do
  @moduledoc """
  Authorization for a Sake endpoint: the host app is the OAuth 2.1
  authorization server, and the endpoint is the resource server.

  Configure it on the `Sake` child (see `Sake.child_spec/1`) and mount the
  routes with `Sake.Router` (Phoenix) or `Sake.Auth.RouterPlug` (Plug).
  """

  alias Sake.Auth.Config

  @spec config() :: Config.t()
  def config do
    :persistent_term.get({Sake, :auth}, nil) ||
      raise "Sake authorization is not configured: start {Sake, auth: [...]}"
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
  Deletes expired codes and tokens, and the remembered consents older than
  the refresh token lifetime that no live token family still uses. Schedule
  it (a cron job, Oban, or a periodic task).
  """
  @spec prune(Config.t()) :: :ok
  def prune(config) do
    {module, state} = store(config)
    now = DateTime.utc_now()
    module.prune(state, now, DateTime.add(now, -config.refresh_token_ttl))
  end
end
