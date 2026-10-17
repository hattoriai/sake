if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Sake.Auth.Store.Ecto.Client do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "sake_oauth_clients" do
      field(:name, :string)
      field(:kind, :string)
      field(:redirect_uris, {:array, :string}, default: [])
      field(:grant_types, {:array, :string}, default: [])
      field(:token_endpoint_auth_method, :string)
      field(:secret_hash, :string)
      field(:logo_uri, :string)
      field(:client_uri, :string)
      field(:scopes, {:array, :string})
      field(:jwks, :map)
      field(:jwks_uri, :string)
      field(:application_type, :string)
      field(:dpop_bound_access_tokens, :boolean, default: false)
      field(:require_pushed_authorization_requests, :boolean, default: false)
      timestamps(type: :utc_datetime)
    end
  end
end
