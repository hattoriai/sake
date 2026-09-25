defmodule Sake.Protocol do
  @moduledoc """
  The protocol revisions Sake speaks and the `_meta` keys the protocol reserves.

  Revision `2026-07-28` is the *modern* era: stateless, one request at a time,
  the protocol version and the client capabilities in every request. The
  three earlier revisions are the *legacy* era with an `initialize`
  handshake and a session.
  """

  @modern "2026-07-28"
  @legacy ["2025-11-25", "2025-06-18", "2025-03-26"]

  @meta %{
    protocol_version: "io.modelcontextprotocol/protocolVersion",
    client_info: "io.modelcontextprotocol/clientInfo",
    client_capabilities: "io.modelcontextprotocol/clientCapabilities",
    server_info: "io.modelcontextprotocol/serverInfo",
    log_level: "io.modelcontextprotocol/logLevel",
    subscription_id: "io.modelcontextprotocol/subscriptionId"
  }

  @type revision :: String.t()
  @type era :: :modern | :legacy

  @spec modern() :: revision()
  def modern, do: @modern

  @spec legacy() :: [revision()]
  def legacy, do: @legacy

  @spec supported() :: [revision()]
  def supported, do: [@modern | @legacy]

  @spec era(revision()) :: era() | :unknown
  def era(@modern), do: :modern
  def era(revision) when revision in @legacy, do: :legacy
  def era(_), do: :unknown

  @spec supported?(term()) :: boolean()
  def supported?(revision), do: revision in supported()

  @doc """
  The legacy revision to serve a client that asked for `requested`: the
  requested one when Sake serves it, otherwise the newest legacy revision
  (the client then decides whether it can speak it).
  """
  @spec negotiate_legacy(term()) :: revision()
  def negotiate_legacy(requested) when requested in @legacy, do: requested
  def negotiate_legacy(_), do: hd(@legacy)

  @spec meta(atom()) :: String.t()
  def meta(key), do: Map.fetch!(@meta, key)
end
