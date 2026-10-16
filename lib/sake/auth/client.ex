defmodule Sake.Auth.Client do
  @moduledoc """
  An OAuth client: from a Client ID Metadata Document, dynamically
  registered, or registered by the host.

  A client registered for `private_key_jwt` authentication carries its
  public keys: a JWK Set in `jwks`, or the URL of one in `jwks_uri`.

  `dpop_bound_access_tokens` (RFC 9449 §5.2) says the client always uses
  DPoP: its token requests without a proof are refused.

  `inserted_at` is when it was registered: a dynamically registered
  client that never came to hold a token or a consent is pruned some time
  after (see `Sake.Auth.prune/1`).
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
    :inserted_at,
    redirect_uris: [],
    grant_types: ["authorization_code", "refresh_token"],
    token_endpoint_auth_method: "none",
    application_type: "native",
    dpop_bound_access_tokens: false
  ]
end
