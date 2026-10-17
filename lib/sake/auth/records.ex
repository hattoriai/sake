defmodule Sake.Auth.Code do
  @moduledoc """
  An authorization code (stored hashed). `dpop_jkt` is the thumbprint of
  the DPoP key the code is bound to (RFC 9449 §10), or nil: the token
  request that redeems a bound code must carry a proof made with that
  key. `acr` and `auth_time` are how and when the person signed in
  when they approved it (`c:Sake.Auth.Subject.authentication/1`), or
  nil, which its tokens carry (RFC 9470).
  """
  @type t :: %__MODULE__{}
  defstruct [
    :hash,
    :client_id,
    :redirect_uri,
    :code_challenge,
    :resource,
    :subject_id,
    :expires_at,
    :dpop_jkt,
    :acr,
    :auth_time,
    scopes: []
  ]
end

defmodule Sake.Auth.PushedRequest do
  @moduledoc """
  A pushed authorization request (RFC 9126), stored by the hash of its
  `request_uri` until the authorize endpoint consumes it, once, or it
  expires. The other fields are the validated request's: `extra` holds
  the parameters a later feature adds (`"dpop_jkt"`, the thumbprint of
  the DPoP key the code will be bound to), with string keys and JSON
  values, so a store can keep it as JSON. It holds `"acr_values"` and
  `"max_age"` too, when the client asks how the person must have signed
  in (RFC 9470).
  """
  @type t :: %__MODULE__{}
  defstruct [
    :hash,
    :client_id,
    :redirect_uri,
    :state,
    :code_challenge,
    :resource,
    :expires_at,
    :inserted_at,
    scopes: [],
    extra: %{}
  ]
end

defmodule Sake.Auth.TokenRecord do
  @moduledoc """
  An access or refresh token (stored hashed). `family_id` groups the
  tokens born from one authorization code. `jkt` is the RFC 7638
  thumbprint of the DPoP key the token is bound to (its `cnf.jkt`), or nil
  for a bearer token. `acr` and `auth_time` are how and when the person
  signed in to approve the grant (RFC 9470), or nil when unknown (and
  always for a machine client); a refresh keeps them, since it is no new
  sign-in.

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
    :acr,
    :auth_time,
    :issuer,
    :claims,
    scopes: []
  ]
end

defmodule Sake.Auth.DeviceGrant do
  @moduledoc """
  A device authorization grant (RFC 8628), stored hashed: `hash` is the
  device code's, `user_code_hash` the user code's. `status` is
  `:pending` until the person decides, then `:approved` (with
  `subject_id` and the `scopes` they granted) or `:denied`, and
  `:issued` once the client has its tokens. `last_polled_at` is when
  the client last asked the token endpoint, against `interval`.

  `extra` holds the device authorization request's parameters that are
  not fields, as `Sake.Auth.PushedRequest`'s does: `"acr_values"` and
  `"max_age"` (RFC 9470), with string keys and JSON values. `acr` and
  `auth_time` are how and when the person who approved it signed in,
  which its tokens carry.
  """
  @type status :: :pending | :approved | :denied | :issued
  @type t :: %__MODULE__{}
  defstruct [
    :hash,
    :user_code_hash,
    :client_id,
    :resource,
    :subject_id,
    :interval,
    :expires_at,
    :last_polled_at,
    :inserted_at,
    :acr,
    :auth_time,
    status: :pending,
    scopes: [],
    extra: %{}
  ]

  @doc """
  The answer to a poll of `grant` by `client_id` at `now`, and the grant
  as it is after it (or nil when nothing changes), by the rules of
  `c:Sake.Auth.Store.poll_device_grant/4`. A store calls it while it
  holds the grant's row, and writes the grant back.
  """
  @spec poll(t(), String.t(), DateTime.t()) ::
          {{:approved, t()} | :pending | :slow_down | :denied | :expired | :used | :error,
           t() | nil}
  def poll(%__MODULE__{client_id: client_id} = grant, client_id, now) do
    polled = %{grant | last_polled_at: now}

    cond do
      grant.status == :issued -> {:used, nil}
      grant.status == :denied -> {:denied, nil}
      DateTime.compare(grant.expires_at, now) != :gt -> {:expired, nil}
      too_soon?(grant, now) -> {:slow_down, polled}
      grant.status == :pending -> {:pending, polled}
      true -> {{:approved, grant}, %{polled | status: :issued}}
    end
  end

  def poll(_grant, _client_id, _now), do: {:error, nil}

  defp too_soon?(%{last_polled_at: nil}, _now), do: false

  defp too_soon?(grant, now),
    do: DateTime.diff(now, grant.last_polled_at, :millisecond) < grant.interval * 1_000
end
