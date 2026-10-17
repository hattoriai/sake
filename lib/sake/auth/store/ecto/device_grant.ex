if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Sake.Auth.Store.Ecto.DeviceGrant do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:hash, :string, autogenerate: false}
    schema "sake_oauth_device_grants" do
      field(:user_code_hash, :string)
      field(:client_id, :string)
      field(:scopes, {:array, :string}, default: [])
      field(:resource, :string)
      field(:status, :string)
      field(:subject_id, :string)
      field(:extra, :map, default: %{})
      field(:acr, :string)
      field(:auth_time, :utc_datetime)
      field(:interval, :integer)
      field(:expires_at, :utc_datetime)
      field(:last_polled_at, :utc_datetime_usec)
      field(:revoked_at, :utc_datetime)
      field(:inserted_at, :utc_datetime)
    end
  end
end
