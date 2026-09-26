defmodule Sake.Server.Session do
  @moduledoc """
  Legacy session IDs are signed tokens that carry the negotiated revision,
  the client capabilities, the log level `logging/setLevel` last set, and
  a random nonce. The server stores nothing per session.

  The nonce is the session's identity: a re-minted ID (after
  `logging/setLevel`, or when the ID gets old) keeps it, so the session's
  GET stream and its resource subscriptions follow the session across
  renewals.
  """

  @salt "sake.session"
  @max_age 30 * 24 * 3_600
  @renew_after 24 * 3_600

  @type session :: %{
          revision: String.t(),
          capabilities: map(),
          minted_at: integer(),
          log_level: String.t() | nil,
          nonce: String.t()
        }

  @doc "Mints a new session ID; `nonce` is the identity of an existing session being renewed."
  @spec mint(binary(), String.t(), map(), String.t() | nil, String.t() | nil) :: String.t()
  def mint(secret, revision, capabilities, log_level \\ nil, nonce \\ nil) do
    Plug.Crypto.sign(secret, @salt, %{
      v: revision,
      c: capabilities,
      t: System.system_time(:second),
      l: log_level,
      n: nonce || new_nonce()
    })
  end

  @doc "Re-mints `session` with the same nonce and the given log level."
  @spec renew(binary(), session(), String.t() | nil) :: String.t()
  def renew(secret, session, log_level),
    do: mint(secret, session.revision, session.capabilities, log_level, session.nonce)

  defp new_nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @spec verify(binary(), term()) :: {:ok, session()} | :error
  def verify(secret, id) when is_binary(id) do
    case Plug.Crypto.verify(secret, @salt, id, max_age: @max_age) do
      {:ok, %{v: v, c: c, t: t, n: n} = payload} when is_binary(n) ->
        {:ok,
         %{
           revision: v,
           capabilities: c,
           minted_at: t,
           log_level: Map.get(payload, :l),
           nonce: n
         }}

      _ ->
        :error
    end
  end

  def verify(_, _), do: :error

  @doc "Whether the ID is old enough to be re-minted on the response."
  @spec renew?(session()) :: boolean()
  def renew?(%{minted_at: t}), do: System.system_time(:second) - t > @renew_after
end
