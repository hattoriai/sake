if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Sake.Auth.Store.Ecto.Replay do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:key, :string, autogenerate: false}
    schema "sake_oauth_replays" do
      field(:expires_at, :utc_datetime)
    end
  end
end
