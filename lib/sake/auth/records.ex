defmodule Sake.Auth.Code do
  @moduledoc "An authorization code (stored hashed)."
  @type t :: %__MODULE__{}
  defstruct [
    :hash,
    :client_id,
    :redirect_uri,
    :code_challenge,
    :resource,
    :subject_id,
    :expires_at,
    scopes: []
  ]
end

defmodule Sake.Auth.TokenRecord do
  @moduledoc """
  An access or refresh token (stored hashed). `family_id` groups the
  tokens born from one authorization code. `jkt` is the RFC 7638
  thumbprint of the DPoP key the token is bound to (its `cnf.jkt`), or nil
  for a bearer token.

  A token from an external authorization server (see
  `Sake.Auth.External`) is never stored: its record is made for each
  request, with that server's `issuer` and the verified `claims` (the
  JWT's, the introspection answer, or what your callback returned). Both
  are nil for a token of `Sake.Auth`.
  """
  @type t :: %__MODULE__{}
  defstruct [
    :id,
    :kind,
    :hash,
    :family_id,
    :client_id,
    :subject_id,
    :resource,
    :expires_at,
    :revoked_at,
    :used_at,
    :inserted_at,
    :jkt,
    :issuer,
    :claims,
    scopes: []
  ]
end
