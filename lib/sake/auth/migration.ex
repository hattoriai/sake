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
        add(:application_type, :string)
        timestamps(type: :utc_datetime)
      end

      create table(:sake_oauth_codes, primary_key: false, prefix: prefix) do
        add(:hash, :string, primary_key: true)
        add(:client_id, :string)
        add(:redirect_uri, :text)
        add(:code_challenge, :string)
        add(:scopes, {:array, :string}, null: false, default: [])
        add(:resource, :text)
        add(:subject_id, :string)
        add(:expires_at, :utc_datetime_usec, null: false)
        timestamps(type: :utc_datetime, updated_at: false)
      end

      create(index(:sake_oauth_codes, [:expires_at], prefix: prefix))

      create table(:sake_oauth_tokens, primary_key: false, prefix: prefix) do
        add(:id, :string, primary_key: true)
        add(:kind, :string, null: false)
        add(:hash, :string, null: false)
        add(:family_id, :string, null: false)
        add(:client_id, :string)
        add(:subject_id, :string, null: false)
        add(:scopes, {:array, :string}, null: false, default: [])
        add(:resource, :text)
        add(:expires_at, :utc_datetime, null: false)
        add(:revoked_at, :utc_datetime)
        add(:used_at, :utc_datetime)
        add(:inserted_at, :utc_datetime, null: false)
      end

      create(unique_index(:sake_oauth_tokens, [:hash], prefix: prefix))
      create(index(:sake_oauth_tokens, [:family_id], prefix: prefix))
      create(index(:sake_oauth_tokens, [:subject_id], prefix: prefix))
      create(index(:sake_oauth_tokens, [:expires_at], prefix: prefix))

      create table(:sake_oauth_consents, primary_key: false, prefix: prefix) do
        add(:subject_id, :string, null: false)
        add(:client_id, :string, null: false)
        add(:scopes, {:array, :string}, null: false, default: [])
        add(:inserted_at, :utc_datetime, null: false)
      end

      create(unique_index(:sake_oauth_consents, [:subject_id, :client_id], prefix: prefix))
      :ok
    end

    @spec down(keyword()) :: :ok
    def down(opts \\ []) do
      prefix = opts[:prefix]
      drop(table(:sake_oauth_consents, prefix: prefix))
      drop(table(:sake_oauth_tokens, prefix: prefix))
      drop(table(:sake_oauth_codes, prefix: prefix))
      drop(table(:sake_oauth_clients, prefix: prefix))
      :ok
    end
  end
end
