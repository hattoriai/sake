if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Sake.Auth.Store.Ecto.Consent do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "sake_oauth_consents" do
      field(:subject_id, :string)
      field(:client_id, :string)
      field(:resource, :string)
      field(:scopes, {:array, :string}, default: [])
      field(:inserted_at, :utc_datetime)
    end
  end
end
