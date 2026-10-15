defmodule Sake.Auth.Client do
  @moduledoc """
  An OAuth client: from a Client ID Metadata Document, dynamically
  registered, or registered by the host.

  A client registered for `private_key_jwt` authentication carries its
  public keys: a JWK Set in `jwks`, or the URL of one in `jwks_uri`.
  """
  @type t :: %__MODULE__{}
  defstruct [
    :id,
    :name,
    :kind,
    :secret_hash,
    :logo_uri,
    :client_uri,
    :scopes,
    :jwks,
    :jwks_uri,
    redirect_uris: [],
    grant_types: ["authorization_code", "refresh_token"],
    token_endpoint_auth_method: "none",
    application_type: "native"
  ]
end
