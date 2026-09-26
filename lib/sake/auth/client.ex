defmodule Sake.Auth.Client do
  @moduledoc "An OAuth client: from a Client ID Metadata Document, dynamically registered, or registered by the host."
  @type t :: %__MODULE__{}
  defstruct [
    :id,
    :name,
    :kind,
    :secret_hash,
    :logo_uri,
    :client_uri,
    :scopes,
    redirect_uris: [],
    grant_types: ["authorization_code", "refresh_token"],
    token_endpoint_auth_method: "none",
    application_type: "native"
  ]
end
