defmodule Sake.Auth.Revocation do
  @moduledoc false
  # Token revocation (RFC 7009). Revoking a refresh token revokes its
  # whole family. Revoking any token of a client also forgets the consents
  # that person gave that client, so the next connection asks again.
  #
  # Core: it takes the configuration, the request's parameters and the
  # client's credentials, and never sees the conn; `Sake.Auth.Revoke`
  # reads the request and renders the answer.

  alias Sake.Auth
  alias Sake.Auth.{ClientAuth, Config, Tokens}

  @doc """
  Revokes the token `params` names, when it belongs to the client the
  request authenticates. A token that is unknown, or another client's,
  is answered like a revoked one (RFC 7009 §2.2): `:ok`. A request that
  names no client at all has nothing to authenticate against, and is
  answered the same way, without a 401.
  """
  @spec revoke(Config.t(), map(), ClientAuth.credentials()) ::
          :ok | {:error, 401, String.t(), String.t()}
  def revoke(config, p, credentials) do
    if ClientAuth.client_given?(credentials, p),
      do: authenticate_and_revoke(config, p, credentials),
      else: :ok
  end

  defp authenticate_and_revoke(config, p, credentials) do
    case ClientAuth.authenticate(config, credentials, p) do
      {:error, :invalid_client} ->
        {:error, 401, "invalid_client", "Client authentication failed"}

      {:ok, client} ->
        if is_binary(p["token"]),
          do: revoke_token(config, client, Tokens.hash(p["token"]), p["token_type_hint"])

        :ok
    end
  end

  defp revoke_token(config, client, hash, hint) do
    {module, state} = Auth.store(config)
    order = if hint == "access_token", do: [:access, :refresh], else: [:refresh, :access]
    Enum.each(order, &revoke_owned(module, state, client, hash, &1))
  end

  defp revoke_owned(module, state, client, hash, kind) do
    with {:ok, %{client_id: cid} = record} <- module.get_token(state, kind, hash),
         true <- cid == client.id do
      revoke_record(module, state, kind, record)
      forget_consent(module, state, record)
    else
      _ -> :ok
    end
  end

  # A machine client's token has no subject, and no consent behind it.
  defp forget_consent(_module, _state, %{subject_id: nil}), do: :ok

  defp forget_consent(module, state, record),
    do: module.delete_consent(state, record.subject_id, record.client_id, :all)

  defp revoke_record(module, state, :refresh, record),
    do: module.revoke_family(state, record.family_id)

  defp revoke_record(module, state, _kind, record), do: module.revoke_token(state, record.id)
end
