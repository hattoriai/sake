if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Sake.Auth.Migration do
    @moduledoc """
    The tables of `Sake.Auth.Store.Ecto`. In your app:

        defmodule MyApp.Repo.Migrations.AddSakeAuth do
          use Ecto.Migration
          def up, do: Sake.Auth.Migration.up()
          def down, do: Sake.Auth.Migration.down()
        end

    Both take `prefix:`.
    """
    use Ecto.Migration

    @spec up(keyword()) :: :ok
    def up(opts \\ []) do
      prefix = opts[:prefix]

      create table(:sake_oauth_clients, primary_key: false, prefix: prefix) do
        add(:id, :string, primary_key: true)
        add(:name, :string, null: false)
        add(:kind, :string, null: false)
        add(:redirect_uris, {:array, :text}, null: false, default: [])
        add(:grant_types, {:array, :string}, null: false, default: [])
        add(:token_endpoint_auth_method, :string, null: false)
        add(:secret_hash, :string)
        add(:logo_uri, :text)
        add(:client_uri, :text)
        add(:scopes, {:array, :string})
        add(:jwks, :map)
        add(:jwks_uri, :text)
        add(:application_type, :string)
        # RFC 9449 §5.2: the client's token requests must carry a DPoP proof.
        add(:dpop_bound_access_tokens, :boolean, null: false, default: false)
        # RFC 9126 §6: the client's authorization requests must be pushed.
        add(:require_pushed_authorization_requests, :boolean, null: false, default: false)
        timestamps(type: :utc_datetime)
      end

      create table(:sake_oauth_codes, primary_key: false, prefix: prefix) do
        add(:hash, :string, primary_key: true)
        add(:client_id, :string, null: false)
        add(:redirect_uri, :text, null: false)
        add(:code_challenge, :string, null: false)
        add(:scopes, {:array, :string}, null: false, default: [])
        add(:resource, :text, null: false)
        add(:subject_id, :string, null: false)
        # The thumbprint of the DPoP key the code is bound to (RFC 9449
        # §10), whose proof must come with the token request.
        add(:dpop_jkt, :string)
        # How and when the person who approved it signed in (RFC 9470),
        # which its tokens carry.
        add(:acr, :string)
        add(:auth_time, :utc_datetime)
        add(:expires_at, :utc_datetime, null: false)
        # A consumed code is kept until it expires, as the fence between
        # issuing its tokens and revoking its family on a replay.
        add(:used_at, :utc_datetime)
        add(:revoked_at, :utc_datetime)
        timestamps(type: :utc_datetime, updated_at: false)
      end

      create(index(:sake_oauth_codes, [:expires_at], prefix: prefix))

      # Pushed authorization requests (RFC 9126), by the hash of their
      # request_uri, until the authorize endpoint takes them, once.
      create table(:sake_oauth_pushed_requests, primary_key: false, prefix: prefix) do
        add(:hash, :string, primary_key: true)
        add(:client_id, :string, null: false)
        add(:redirect_uri, :text, null: false)
        add(:state, :text)
        add(:code_challenge, :string, null: false)
        add(:scopes, {:array, :string}, null: false, default: [])
        add(:resource, :text, null: false)
        add(:extra, :map, null: false, default: %{})
        add(:expires_at, :utc_datetime, null: false)
        add(:inserted_at, :utc_datetime, null: false)
      end

      create(index(:sake_oauth_pushed_requests, [:expires_at], prefix: prefix))

      # Device authorization grants (RFC 8628), by the device code's hash,
      # with the user code's hash for the verification page. Like a
      # consumed code, an issued grant is kept until it expires, as the
      # fence between issuing its tokens and revoking its family.
      create table(:sake_oauth_device_grants, primary_key: false, prefix: prefix) do
        add(:hash, :string, primary_key: true)
        add(:user_code_hash, :string, null: false)
        add(:client_id, :string, null: false)
        add(:scopes, {:array, :string}, null: false, default: [])
        add(:resource, :text, null: false)
        add(:status, :string, null: false)
        add(:subject_id, :string)
        # The request's acr_values and max_age (RFC 9470), and how and
        # when the person who approved it signed in.
        add(:extra, :map, null: false, default: %{})
        add(:acr, :string)
        add(:auth_time, :utc_datetime)
        add(:interval, :integer, null: false)
        add(:expires_at, :utc_datetime, null: false)
        add(:last_polled_at, :utc_datetime_usec)
        add(:revoked_at, :utc_datetime)
        add(:inserted_at, :utc_datetime, null: false)
      end

      create(unique_index(:sake_oauth_device_grants, [:user_code_hash], prefix: prefix))
      create(index(:sake_oauth_device_grants, [:expires_at], prefix: prefix))

      create table(:sake_oauth_tokens, primary_key: false, prefix: prefix) do
        add(:id, :string, primary_key: true)
        add(:kind, :string, null: false)
        add(:hash, :string, null: false)
        add(:family_id, :string, null: false)
        add(:client_id, :string, null: false)
        # A machine client's token (the client credentials grant) has no
        # subject: the client itself is the principal.
        add(:subject_id, :string)
        add(:scopes, {:array, :string}, null: false, default: [])
        add(:resource, :text, null: false)
        add(:expires_at, :utc_datetime, null: false)
        add(:revoked_at, :utc_datetime)
        add(:used_at, :utc_datetime)
        add(:inserted_at, :utc_datetime, null: false)
        # The thumbprint of the DPoP key a token is bound to (RFC 9449
        # `cnf.jkt`); a bearer token has none.
        add(:jkt, :string)
        # How and when the person signed in to approve the grant (RFC
        # 9470); a refresh keeps them.
        add(:acr, :string)
        add(:auth_time, :utc_datetime)
      end

      create(unique_index(:sake_oauth_tokens, [:hash], prefix: prefix))
      create(index(:sake_oauth_tokens, [:family_id], prefix: prefix))
      create(index(:sake_oauth_tokens, [:subject_id], prefix: prefix))
      create(index(:sake_oauth_tokens, [:expires_at], prefix: prefix))

      create table(:sake_oauth_consents, primary_key: false, prefix: prefix) do
        add(:subject_id, :string, null: false)
        add(:client_id, :string, null: false)
        add(:resource, :text, null: false)
        add(:scopes, {:array, :string}, null: false, default: [])
        add(:inserted_at, :utc_datetime, null: false)
      end

      create(
        unique_index(:sake_oauth_consents, [:subject_id, :client_id, :resource], prefix: prefix)
      )

      # The single-use JWTs already seen (client assertions, JWT grants,
      # DPoP proofs), by a digest of their issuer and `jti`, until they
      # expire.
      create table(:sake_oauth_replays, primary_key: false, prefix: prefix) do
        add(:key, :string, primary_key: true)
        add(:expires_at, :utc_datetime, null: false)
      end

      create(index(:sake_oauth_replays, [:expires_at], prefix: prefix))

      :ok
    end

    @spec down(keyword()) :: :ok
    def down(opts \\ []) do
      prefix = opts[:prefix]
      drop(table(:sake_oauth_replays, prefix: prefix))
      drop(table(:sake_oauth_consents, prefix: prefix))
      drop(table(:sake_oauth_tokens, prefix: prefix))
      drop(table(:sake_oauth_device_grants, prefix: prefix))
      drop(table(:sake_oauth_pushed_requests, prefix: prefix))
      drop(table(:sake_oauth_codes, prefix: prefix))
      drop(table(:sake_oauth_clients, prefix: prefix))
      :ok
    end
  end
end
