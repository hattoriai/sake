defmodule SakeTest.LegacyClient do
  @moduledoc false
  # Drives Sake.Plug through Plug.Test as a handshake-era client.
  import Plug.Test
  import Plug.Conn

  def initialize(plug_opts, revision \\ "2025-06-18", capabilities \\ %{}) do
    conn =
      raw(
        plug_opts,
        nil,
        Sake.JSONRPC.request(0, "initialize", %{
          "protocolVersion" => revision,
          "capabilities" => capabilities,
          "clientInfo" => %{"name" => "legacy-test", "version" => "0"}
        }),
        header: revision != "2025-03-26" && revision
      )

    200 = conn.status
    [session] = get_resp_header(conn, "mcp-session-id")
    result = JSON.decode!(conn.resp_body)["result"]

    _ =
      raw(plug_opts, session, Sake.JSONRPC.notification("notifications/initialized"),
        header: result["protocolVersion"] != "2025-03-26" && result["protocolVersion"]
      )

    %{id: session, revision: result["protocolVersion"], result: result}
  end

  def post(plug_opts, session, method, params \\ %{}, opts \\ []) do
    body =
      if opts[:notification],
        do: Sake.JSONRPC.notification(method, params),
        else: Sake.JSONRPC.request(opts[:id] || 1, method, params)

    raw(plug_opts, session.id, body, header: session.revision != "2025-03-26" && session.revision)
  end

  def raw(plug_opts, session_id, body, opts) do
    conn =
      conn(:post, "/mcp", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn = if session_id, do: put_req_header(conn, "mcp-session-id", session_id), else: conn

    conn =
      if opts[:header],
        do: put_req_header(conn, "mcp-protocol-version", opts[:header]),
        else: conn

    Sake.Plug.call(conn, plug_opts)
  end

  def json(conn), do: JSON.decode!(conn.resp_body)
end
