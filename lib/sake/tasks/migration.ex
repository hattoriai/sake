if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Sake.Tasks.Migration do
    @moduledoc """
    The table of `Sake.Tasks.Store.Ecto`. In your app:

        defmodule MyApp.Repo.Migrations.AddSakeTasks do
          use Ecto.Migration
          def up, do: Sake.Tasks.Migration.up()
          def down, do: Sake.Tasks.Migration.down()
        end

    Both take `prefix:`.
    """
    use Ecto.Migration

    @spec up(keyword()) :: :ok
    def up(opts \\ []) do
      prefix = opts[:prefix]

      create table(:sake_tasks, primary_key: false, prefix: prefix) do
        add(:id, :string, primary_key: true)
        add(:principal, :string)
        add(:tool, :string, null: false)
        add(:status, :string, null: false)
        add(:status_message, :text)
        add(:input_requests, :map, null: false, default: %{})
        add(:answers, :map, null: false, default: %{})
        add(:result, :map)
        add(:error, :map)
        add(:ttl_ms, :integer, null: false)
        add(:poll_interval_ms, :integer, null: false)
        add(:created_at, :utc_datetime_usec, null: false)
        add(:updated_at, :utc_datetime_usec, null: false)
        add(:expires_at, :utc_datetime_usec, null: false)
      end

      create(index(:sake_tasks, [:expires_at], prefix: prefix))
      :ok
    end

    @spec down(keyword()) :: :ok
    def down(opts \\ []) do
      drop(table(:sake_tasks, prefix: opts[:prefix]))
      :ok
    end
  end
end
