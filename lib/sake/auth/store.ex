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
  @callback consume_code(state(), String.t()) :: {:ok, Code.t()} | :error
  @callback put_token(state(), TokenRecord.t()) :: :ok
  @callback get_token(state(), :access | :refresh, String.t()) :: {:ok, TokenRecord.t()} | :error
  @callback mark_used(state(), String.t()) :: :ok
  @callback revoke_token(state(), String.t()) :: :ok
  @callback revoke_family(state(), String.t()) :: :ok
  @callback tokens_for_subject(state(), String.t()) :: [TokenRecord.t()]
  @callback put_consent(state(), Consent.t()) :: :ok
  @callback get_consent(state(), String.t(), String.t()) :: {:ok, Consent.t()} | :error
  @callback delete_consent(state(), String.t(), String.t()) :: :ok
  @callback prune(state(), DateTime.t()) :: :ok
end
