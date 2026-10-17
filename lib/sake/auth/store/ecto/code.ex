if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Sake.Auth.Store.Ecto.Code do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:hash, :string, autogenerate: false}
    schema "sake_oauth_codes" do
      field(:client_id, :string)
      field(:redirect_uri, :string)
      field(:code_challenge, :string)
      field(:scopes, {:array, :string}, default: [])
      field(:resource, :string)
      field(:subject_id, :string)
      field(:dpop_jkt, :string)
      field(:acr, :string)
      field(:auth_time, :utc_datetime)
      field(:expires_at, :utc_datetime)
      field(:used_at, :utc_datetime)
      field(:revoked_at, :utc_datetime)
      timestamps(type: :utc_datetime, updated_at: false)
    end
  end
end
