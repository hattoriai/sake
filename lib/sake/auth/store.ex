defmodule Sake.Auth.Store do
  @moduledoc "Where clients, codes, pushed authorization requests, device grants, tokens and consents live. Implemented by `Sake.Auth.Store.ETS` and `Sake.Auth.Store.Ecto`."
  alias Sake.Auth.{Client, Code, Consent, DeviceGrant, PushedRequest, TokenRecord}
  @type state :: term()
  @callback init(keyword()) :: state()
  @callback put_client(state(), Client.t()) :: :ok
  @callback get_client(state(), String.t()) :: {:ok, Client.t()} | :error
  @callback list_clients(state()) :: [Client.t()]
  @callback delete_client(state(), String.t()) :: :ok
  @callback put_code(state(), Code.t()) :: :ok
  @doc """
  Consumes a code, if and only if it was not consumed yet, atomically. The
  store keeps knowing the consumed code until it expires, as the fence
  `put_code_tokens/3` checks.
  """
  @callback consume_code(state(), String.t()) :: {:ok, Code.t()} | :error
  @doc """
  Stores the tokens issued for a consumed code (their `family_id` is the
  code's hash), all of them or none: none, returning `:revoked`, when the
  family was revoked since the code was consumed (a replay of the code).
  A store may refuse a code it no longer knows the same way. Atomic with `revoke_family/2`: whichever of the
  two runs second sees the other's effect, so a replay never leaves a
  live pair behind.
  """
  @callback put_code_tokens(state(), code_hash :: String.t(), [TokenRecord.t()]) ::
              :ok | :revoked
  @callback put_pushed_request(state(), PushedRequest.t()) :: :ok
  @doc """
  Takes the pushed authorization request whose `request_uri` has this
  hash, if and only if nobody took it before, atomically: of two
  concurrent calls, one gets it and the other `:error`. The store may
  forget it then; the caller checks its expiry and its client.
  """
  @callback consume_pushed_request(state(), hash :: String.t()) ::
              {:ok, PushedRequest.t()} | :error
  @callback put_device_grant(state(), DeviceGrant.t()) :: :ok
  @callback get_device_grant_by_user_code(state(), user_code_hash :: String.t()) ::
              {:ok, DeviceGrant.t()} | :error
  @doc """
  Records the person's decision on a pending device grant (by its
  device code's hash), if and only if it is still pending, atomically:
  of two concurrent decisions, one gets `:ok` and the other `:error`.
  An approval sets `subject_id` and narrows `scopes` to those granted.
  """
  @callback decide_device_grant(
              state(),
              hash :: String.t(),
              {:approved, subject_id :: String.t(), scopes :: [String.t()]} | :denied
            ) :: :ok | :error
  @doc """
  A poll of the token endpoint for the device grant `hash`, by the
  client `client_id`, at `now`, atomically. `:error` for a grant that
  does not exist or is another client's; then, in this order, `:used`
  once its tokens were issued, `:denied`, `:expired` (from
  `expires_at`), `:slow_down` when the last poll was less than
  `interval` seconds ago, `:pending`, and `{:approved, grant}` for an
  approved grant, which becomes `:issued`: of two concurrent polls, only
  one gets it. Every poll but the first three records `now` as
  `last_polled_at`.
  """
  @callback poll_device_grant(
              state(),
              hash :: String.t(),
              client_id :: String.t(),
              now :: DateTime.t()
            ) ::
              {:approved, DeviceGrant.t()}
              | :pending
              | :slow_down
              | :denied
              | :expired
              | :used
              | :error
  @doc """
  Stores the tokens issued for a device grant (their `family_id` is its
  hash), all of them or none: none, returning `:revoked`, when the
  family was revoked since the grant was issued (a replay of the device
  code). Atomic with `revoke_family/2`, as `put_code_tokens/3` is.
  """
  @callback put_device_tokens(state(), hash :: String.t(), [TokenRecord.t()]) ::
              :ok | :revoked
  @callback put_token(state(), TokenRecord.t()) :: :ok
  @doc """
  Stores the tokens a refresh rotated into, all of them or none: none,
  returning `:revoked`, when the refresh token they replace (by hash) is
  revoked or gone, as a concurrent reuse of it revokes its family.
  Atomic with `revoke_family/2`: whichever of the two runs second sees
  the other's effect.
  """
  @callback put_rotated_tokens(state(), refresh_hash :: String.t(), [TokenRecord.t()]) ::
              :ok | :revoked
  @callback get_token(state(), :access | :refresh, String.t()) :: {:ok, TokenRecord.t()} | :error
  @doc """
  Marks a refresh token used now, if and only if it was unused, atomically:
  two concurrent calls for the same hash must not both succeed. Returns the
  record as it was *before* this call.
  """
  @callback consume_refresh(state(), String.t()) ::
              {:ok, TokenRecord.t()} | {:error, :used, TokenRecord.t()} | :error
  @callback revoke_token(state(), String.t()) :: :ok
  @doc """
  Revokes every token of a family, and the code or device grant whose
  hash is the family's id, so that `put_code_tokens/3` and
  `put_device_tokens/3` refuse the tokens not stored yet.
  """
  @callback revoke_family(state(), String.t()) :: :ok
  @callback tokens_for_subject(state(), String.t()) :: [TokenRecord.t()]
  @doc """
  Records `key` (a digest naming a single-use JWT: a client assertion, a
  JWT grant, a DPoP proof) until `expires_at`, in Unix seconds: `:ok` the
  first time, `:replayed` while it is recorded. Atomic across every node
  that shares the store: of two calls with the same key, exactly one gets
  `:ok`.
  """
  @callback once(state(), key :: String.t(), expires_at :: integer()) :: :ok | :replayed
  @doc "Forgets the keys `once/3` recorded that expired by `now`, in Unix seconds."
  @callback prune_once(state(), now :: integer()) :: :ok
  @doc "Remembers an approval, keyed by subject, client and resource (replacing an earlier one)."
  @callback put_consent(state(), Consent.t()) :: :ok
  @callback get_consent(
              state(),
              subject_id :: String.t(),
              client_id :: String.t(),
              resource :: String.t()
            ) ::
              {:ok, Consent.t()} | :error
  @doc "Forgets the approval for one resource, or for every resource with `:all`."
  @callback delete_consent(
              state(),
              subject_id :: String.t(),
              client_id :: String.t(),
              resource :: String.t() | :all
            ) :: :ok
  @doc """
  Deletes the codes, pushed authorization requests, device grants and
  tokens that expired by `now`; the consents inserted before
  `before.consents` whose subject, client and resource have no live
  (unexpired, unrevoked) refresh token left; and the dynamically
  registered clients registered before `before.unused_clients` that hold
  no live token, no consent, no code, no pushed request and no device
  grant.
  """
  @callback prune(
              state(),
              now :: DateTime.t(),
              before :: %{consents: DateTime.t(), unused_clients: DateTime.t()}
            ) :: :ok
end
