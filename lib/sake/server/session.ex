defmodule Sake.Server.Session do
  @moduledoc """
  Legacy session IDs are signed tokens that carry the negotiated revision,
  the client capabilities, the client's name, title and version (from the
  `clientInfo` of its `initialize`, what components see as
  `ctx.client_info`), the log level `logging/setLevel` last set, and a
  random nonce. The server stores nothing per session.

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
          client_info: map(),
          minted_at: integer(),
          log_level: String.t() | nil,
          nonce: String.t()
        }

  @doc """
  Mints a new session ID for the client's `clientInfo`, of which it keeps
  the name, title and version (see `client_info/1`).
  """
  @spec mint(binary(), String.t(), map(), term()) :: String.t()
  def mint(secret, revision, capabilities, client_info \\ %{}),
    do: sign(secret, revision, capabilities, client_info(client_info), nil, new_nonce())

  @doc "Re-mints `session` with the same nonce and the given log level."
  @spec renew(binary(), session(), String.t() | nil) :: String.t()
  def renew(secret, session, log_level),
    do:
      sign(
        secret,
        session.revision,
        session.capabilities,
        session.client_info,
        log_level,
        session.nonce
      )

  defp sign(secret, revision, capabilities, client_info, log_level, nonce) do
    Plug.Crypto.sign(secret, @salt, %{
      v: revision,
      c: capabilities,
      i: client_info,
      t: System.system_time(:second),
      l: log_level,
      n: nonce
    })
  end

  @doc """
  The part of a client's `clientInfo` a session keeps: its `name`,
  `title` and `version`, when they are strings. The ID travels in a
  header on every request, so the rest (icons, a website URL) stays out.
  """
  @spec client_info(term()) :: map()
  def client_info(info) when is_map(info),
    do:
      info |> Map.take(["name", "title", "version"]) |> Map.filter(fn {_, v} -> is_binary(v) end)

  def client_info(_info), do: %{}

  defp new_nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @spec verify(binary(), term()) :: {:ok, session()} | :error
  def verify(secret, id) when is_binary(id) do
    case Plug.Crypto.verify(secret, @salt, id, max_age: @max_age) do
      {:ok, %{v: v, c: c, t: t, n: n} = payload} when is_binary(n) ->
        {:ok,
         %{
           revision: v,
           capabilities: c,
           client_info: Map.get(payload, :i, %{}),
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
