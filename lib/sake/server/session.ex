defmodule Sake.Server.Session do
  @moduledoc """
  Legacy session IDs are signed tokens that carry the negotiated revision
  and the client capabilities. The server stores nothing per session.
  """

  @salt "sake.session"
  @max_age 30 * 24 * 3_600
  @renew_after 24 * 3_600

  @type session :: %{revision: String.t(), capabilities: map(), minted_at: integer()}

  @spec mint(binary(), String.t(), map()) :: String.t()
  def mint(secret, revision, capabilities) do
    Plug.Crypto.sign(secret, @salt, %{
      v: revision,
      c: capabilities,
      t: System.system_time(:second)
    })
  end

  @spec verify(binary(), term()) :: {:ok, session()} | :error
  def verify(secret, id) when is_binary(id) do
    case Plug.Crypto.verify(secret, @salt, id, max_age: @max_age) do
      {:ok, %{v: v, c: c, t: t}} -> {:ok, %{revision: v, capabilities: c, minted_at: t}}
      _ -> :error
    end
  end

  def verify(_, _), do: :error

  @doc "Whether the ID is old enough to be re-minted on the response."
  @spec renew?(session()) :: boolean()
  def renew?(%{minted_at: t}), do: System.system_time(:second) - t > @renew_after
end
