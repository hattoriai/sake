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

defmodule Sake.Auth.Token do
  @moduledoc "An access or refresh token (stored hashed). `family_id` groups the tokens born from one authorization code."
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
    scopes: []
  ]
end

defmodule Sake.Auth.Consent do
  @moduledoc "A remembered approval of a client by a subject."
  @type t :: %__MODULE__{}
  defstruct [:subject_id, :client_id, :inserted_at, scopes: []]
end
