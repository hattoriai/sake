if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Sake.Auth.Store.Ecto.PushedRequest do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:hash, :string, autogenerate: false}
    schema "sake_oauth_pushed_requests" do
      field(:client_id, :string)
      field(:redirect_uri, :string)
      field(:state, :string)
      field(:code_challenge, :string)
      field(:scopes, {:array, :string}, default: [])
      field(:resource, :string)
      field(:extra, :map, default: %{})
      field(:expires_at, :utc_datetime)
      field(:inserted_at, :utc_datetime)
    end
  end
end
