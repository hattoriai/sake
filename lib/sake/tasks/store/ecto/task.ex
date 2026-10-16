if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Sake.Tasks.Store.Ecto.Task do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "sake_tasks" do
      field(:principal, :string)
      field(:tool, :string)
      field(:scopes, {:array, :string}, default: [])
      field(:status, :string)
      field(:status_message, :string)
      field(:input_requests, :map, default: %{})
      field(:answers, :map, default: %{})
      field(:result, :map)
      field(:error, :map)
      field(:ttl_ms, :integer)
      field(:poll_interval_ms, :integer)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
      field(:expires_at, :utc_datetime_usec)
    end
  end
end
