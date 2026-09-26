if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Sake.Auth.Store.Ecto.Token do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "sake_oauth_tokens" do
      field(:kind, :string)
      field(:hash, :string)
      field(:family_id, :string)
      field(:client_id, :string)
      field(:subject_id, :string)
      field(:scopes, {:array, :string}, default: [])
      field(:resource, :string)
      field(:expires_at, :utc_datetime)
      field(:revoked_at, :utc_datetime)
      field(:used_at, :utc_datetime)
      field(:inserted_at, :utc_datetime)
    end
  end
end
