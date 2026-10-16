defmodule Sake.Auth.Store do
  @moduledoc "Where clients, codes, tokens and consents live. Implemented by `Sake.Auth.Store.ETS` and `Sake.Auth.Store.Ecto`."
  alias Sake.Auth.{Client, Code, Consent, TokenRecord}
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
  @callback put_token(state(), TokenRecord.t()) :: :ok
  @callback get_token(state(), :access | :refresh, String.t()) :: {:ok, TokenRecord.t()} | :error
  @doc """
  Marks a refresh token used now, if and only if it was unused, atomically:
  two concurrent calls for the same hash must not both succeed. Returns the
  record as it was *before* this call.
  """
  @callback consume_refresh(state(), String.t()) ::
              {:ok, TokenRecord.t()} | {:error, :used, TokenRecord.t()} | :error
  @callback revoke_token(state(), String.t()) :: :ok
  @callback revoke_family(state(), String.t()) :: :ok
  @callback tokens_for_subject(state(), String.t()) :: [TokenRecord.t()]
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
  Deletes the codes and tokens that expired by `now`, and the consents
  inserted before `consents_before` whose subject, client and resource
  have no live (unexpired, unrevoked) refresh token left.
  """
  @callback prune(state(), now :: DateTime.t(), consents_before :: DateTime.t()) :: :ok
end
