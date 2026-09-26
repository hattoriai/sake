defmodule Sake.Client.ProbeTest do
  use ExUnit.Case, async: true

  alias Sake.Client

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, url: "http://localhost:#{bypass.port}/mcp"}
  end

  defp json(conn, status, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, JSON.encode!(body))

  defp read(conn),
    do: ({:ok, body, conn} = Plug.Conn.read_body(conn)) && {JSON.decode!(body), conn}

  test "a modern server is detected from server/discover", %{bypass: bypass, url: url} do
    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {msg, conn} = read(conn)
      assert msg["method"] == "server/discover"
      assert Plug.Conn.get_req_header(conn, "mcp-protocol-version") == ["2026-07-28"]
      assert Plug.Conn.get_req_header(conn, "mcp-method") == ["server/discover"]
      assert msg["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"

      json(conn, 200, %{
        "jsonrpc" => "2.0",
        "id" => msg["id"],
        "result" => %{
          "resultType" => "complete",
          "supportedVersions" => ["2026-07-28"],
          "capabilities" => %{"tools" => %{}},
          "instructions" => "hi",
          "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => "S", "version" => "1"}}
        }
      })
    end)

    assert {:ok, session} = Client.connect(url)
    assert session.era == :modern and session.revision == "2026-07-28"

    assert session.server_info == %{"name" => "S", "version" => "1"} and
             session.instructions == "hi"
  end

  test "an unsupported version answer makes the client retry with a supported one", %{
    bypass: bypass,
    url: url
  } do
    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {msg, conn} = read(conn)

      case Plug.Conn.get_req_header(conn, "mcp-protocol-version") do
        ["2026-07-28"] ->
          json(conn, 400, %{
            "jsonrpc" => "2.0",
            "id" => msg["id"],
            "error" => %{
              "code" => -32_022,
              "message" => "Unsupported",
              "data" => %{"supported" => ["2027-01-01"], "requested" => "2026-07-28"}
            }
          })
      end
    end)

    assert {:error, {:no_common_version, ["2027-01-01"]}} = Client.connect(url)
  end

  test "a 4xx without a modern error body means legacy", %{bypass: bypass, url: url} do
    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {msg, conn} = read(conn)

      case msg["method"] do
        "server/discover" ->
          Plug.Conn.resp(conn, 404, "")

        "initialize" ->
          assert msg["params"]["protocolVersion"] == "2025-11-25"

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "s1")
          |> json(200, %{
            "jsonrpc" => "2.0",
            "id" => msg["id"],
            "result" => %{
              "protocolVersion" => "2025-06-18",
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "L", "version" => "1"}
            }
          })

        "notifications/initialized" ->
          assert Plug.Conn.get_req_header(conn, "mcp-session-id") == ["s1"]
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    assert {:ok, session} = Client.connect(url)

    assert session.era == :legacy and session.revision == "2025-06-18" and
             session.session_id == "s1"
  end

  test "a 401 surfaces the challenge", %{bypass: bypass, url: url} do
    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "www-authenticate",
        ~s(Bearer resource_metadata="http://x/.well-known/oauth-protected-resource", scope="a")
      )
      |> Plug.Conn.resp(401, "")
    end)

    assert {:error, {:unauthorized, %Sake.Client.Challenge{scope: ["a"]}}} = Client.connect(url)
  end

  test "a recognized modern error over HTTP 200 is reported as an RPC error", %{
    bypass: bypass,
    url: url
  } do
    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {msg, conn} = read(conn)

      json(conn, 200, %{
        "jsonrpc" => "2.0",
        "id" => msg["id"],
        "error" => %{"code" => -32_602, "message" => "Invalid params"}
      })
    end)

    assert {:error, {:rpc, %{"code" => -32_602}}} = Client.connect(url)
  end

  test "static headers are sent", %{bypass: bypass, url: url} do
    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t"]
      {msg, conn} = read(conn)

      json(conn, 200, %{
        "jsonrpc" => "2.0",
        "id" => msg["id"],
        "result" => %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{}}
      })
    end)

    assert {:ok, _} = Client.connect(url, headers: [{"authorization", "Bearer t"}])
  end
end
