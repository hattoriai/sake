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

    A table created before Sake recovered task execution lacks its
    columns: add them with `add_execution/1` (and remove them with
    `remove_execution/1`):

        defmodule MyApp.Repo.Migrations.AddSakeTaskExecution do
          use Ecto.Migration
          def up, do: Sake.Tasks.Migration.add_execution()
          def down, do: Sake.Tasks.Migration.remove_execution()
        end
    """
    use Ecto.Migration

    @spec up(keyword()) :: :ok
    def up(opts \\ []) do
      prefix = opts[:prefix]

      create table(:sake_tasks, primary_key: false, prefix: prefix) do
        add(:id, :string, primary_key: true)
        add(:principal, :string)
        add(:tool, :string, null: false)
        add(:scopes, {:array, :string}, null: false, default: [])
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
      create(index(:sake_tasks, [:principal, :status], prefix: prefix))
      add_execution(opts)
    end

    @doc "Adds the columns of recoverable execution to a table created before them."
    @spec add_execution(keyword()) :: :ok
    def add_execution(opts \\ []) do
      prefix = opts[:prefix]

      alter table(:sake_tasks, prefix: prefix) do
        add(:job, :binary)
        add(:attempt, :integer, null: false, default: 1)
        add(:lease_owner, :string)
        add(:lease_until, :utc_datetime_usec)
        add(:handle, :string)
      end

      create(index(:sake_tasks, [:status, :lease_until], prefix: prefix))
      :ok
    end

    @doc "Removes the columns `add_execution/1` added."
    @spec remove_execution(keyword()) :: :ok
    def remove_execution(opts \\ []) do
      prefix = opts[:prefix]
      drop(index(:sake_tasks, [:status, :lease_until], prefix: prefix))

      alter table(:sake_tasks, prefix: prefix) do
        remove(:job)
        remove(:attempt)
        remove(:lease_owner)
        remove(:lease_until)
        remove(:handle)
      end

      :ok
    end

    @spec down(keyword()) :: :ok
    def down(opts \\ []) do
      drop(table(:sake_tasks, prefix: opts[:prefix]))
      :ok
    end
  end
end
