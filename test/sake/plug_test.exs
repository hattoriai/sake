defmodule Sake.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias SakeTest.{LegacyClient, ModernClient}

  setup do
    %{opts: ModernClient.opts()}
  end

  defmodule BoomPrompt do
    @moduledoc false
    use Sake.Prompt, name: "boom", description: "fails"

    @impl true
    def get(%{mode: "throw"}, _ctx), do: throw(:nope)
    def get(%{mode: "exit"}, _ctx), do: exit(:gone)
    def get(_args, _ctx), do: raise("kaboom")

    arg :mode, :string
  end

  defmodule BoomServer do
    @moduledoc false
    use Sake.Server, name: "boom", version: "1"
    prompts [BoomPrompt]
  end

  describe "failures and malformed parameters" do
    test "a failing handler on the plain JSON path is -32603, on both eras" do
      opts = ModernClient.opts(server: BoomServer)

      for mode <- ["raise", "throw", "exit"] do
        conn =
          ModernClient.post(opts, "prompts/get", %{
            "name" => "boom",
            "arguments" => %{"mode" => mode}
          })

        assert conn.status == 200, mode
        assert ["application/json" <> _] = get_resp_header(conn, "content-type")

        assert %{
                 "id" => 1,
                 "error" => %{"code" => -32_603, "message" => "The request failed: " <> _}
               } =
                 ModernClient.json(conn)
      end

      session = LegacyClient.initialize(opts, "2025-06-18")
      conn = LegacyClient.post(opts, session, "prompts/get", %{"name" => "boom"})

      assert %{"error" => %{"code" => -32_603, "message" => "The request failed: kaboom"}} =
               LegacyClient.json(conn)
    end

    test "non-object arguments, _meta or inputResponses are -32602", %{opts: opts} do
      for {params, name} <- [
            {%{"name" => "echo", "arguments" => ["hi"]}, "arguments"},
            {%{"name" => "echo", "arguments" => %{}, "inputResponses" => "x"}, "inputResponses"}
          ] do
        conn = ModernClient.post(opts, "tools/call", params, mirror: false)
        assert conn.status == 400

        assert %{"error" => %{"code" => -32_602, "message" => message}} = ModernClient.json(conn)
        assert message == "#{name} must be an object"
      end

      conn =
        conn(
          :post,
          "/mcp",
          JSON.encode!(Sake.JSONRPC.request(3, "tools/list", %{"_meta" => [1]}))
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> Sake.Plug.call(opts)

      assert conn.status == 400

      assert %{"id" => 3, "error" => %{"code" => -32_602, "message" => "_meta must be an object"}} =
               ModernClient.json(conn)

      session = LegacyClient.initialize(opts, "2025-06-18")

      conn =
        LegacyClient.post(opts, session, "tools/call", %{"name" => "echo", "arguments" => 1})

      assert %{"error" => %{"code" => -32_602}} = LegacyClient.json(conn)
    end
  end

  describe "modern POST" do
    test "tools/list and tools/call", %{opts: opts} do
      conn = ModernClient.post(opts, "tools/list")
      assert conn.status == 200
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      assert %{"result" => %{"tools" => [_ | _], "resultType" => "complete"}} =
               ModernClient.json(conn)

      assert get_resp_header(conn, "mcp-session-id") == []

      conn =
        ModernClient.post(
          opts,
          "tools/call",
          %{"name" => "add", "arguments" => %{"a" => 1, "b" => 2, "precision" => 1}},
          params: [{"Precision", 1}]
        )

      assert %{"result" => %{"structuredContent" => %{"sum" => 3.0}}} = ModernClient.json(conn)
    end

    test "header validation", %{opts: opts} do
      conn =
        ModernClient.post(opts, "tools/call", %{
          "name" => "add",
          "arguments" => %{"a" => 1, "b" => 2, "precision" => 1}
        })

      assert conn.status == 400

      assert %{
               "error" => %{
                 "code" => -32_020,
                 "message" => "Mcp-Param-Precision header is missing"
               }
             } = ModernClient.json(conn)

      conn = ModernClient.post(opts, "tools/list", %{}, mirror: false)
      assert conn.status == 400 and ModernClient.json(conn)["error"]["code"] == -32_020

      conn =
        ModernClient.post(opts, "tools/list", %{},
          meta: %{"io.modelcontextprotocol/protocolVersion" => "2025-11-25"}
        )

      assert conn.status == 400 and ModernClient.json(conn)["error"]["code"] == -32_020

      conn =
        ModernClient.post(opts, "tools/list", %{},
          meta: %{"io.modelcontextprotocol/clientCapabilities" => nil}
        )

      assert conn.status == 400 and ModernClient.json(conn)["error"]["code"] == -32_602
    end

    test "unknown version, unknown method, notification, batch", %{opts: opts} do
      conn = ModernClient.post(opts, "tools/list", %{}, version: "2099-01-01")
      assert conn.status == 400

      assert %{
               "error" => %{
                 "code" => -32_022,
                 "data" => %{
                   "supported" => ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"],
                   "requested" => "2099-01-01"
                 }
               }
             } = ModernClient.json(conn)

      conn = ModernClient.post(opts, "nope")
      assert conn.status == 404 and ModernClient.json(conn)["error"]["code"] == -32_601

      conn =
        ModernClient.post(opts, "notifications/cancelled", %{"requestId" => 1},
          notification: true,
          mirror: false
        )

      assert conn.status == 202 and conn.resp_body == ""

      body = JSON.encode!([Sake.JSONRPC.request(1, "tools/list", %{"_meta" => %{}})])

      conn =
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> Sake.Plug.call(opts)

      assert conn.status == 400 and
               ModernClient.json(conn)["error"]["message"] == "Batches are not accepted"
    end

    test "accept, json, size, origin", %{opts: opts} do
      conn = ModernClient.post(opts, "tools/list", %{}, headers: [{"accept", "application/json"}])
      assert conn.status == 406

      conn =
        conn(:post, "/mcp", "{oops")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> Sake.Plug.call(opts)

      assert conn.status == 400 and ModernClient.json(conn)["error"]["code"] == -32_700

      small = ModernClient.opts(json_limit: 50)

      conn =
        ModernClient.post(small, "tools/call", %{
          "name" => "echo",
          "arguments" => %{"text" => String.duplicate("x", 100)}
        })

      assert conn.status == 413

      conn =
        ModernClient.post(opts, "tools/list", %{}, headers: [{"origin", "https://evil.example"}])

      assert conn.status == 403 and
               ModernClient.json(conn)["error"]["message"] == "Origin not allowed"

      conn =
        ModernClient.post(opts, "tools/list", %{},
          headers: [{"origin", "http://www.example.com"}]
        )

      assert conn.status == 403 and
               ModernClient.json(conn)["error"]["message"] == "Origin not allowed"

      conn =
        ModernClient.post(ModernClient.opts(origins: ["https://app.example"]), "tools/list", %{},
          headers: [{"origin", "https://app.example"}]
        )

      assert conn.status == 200

      conn =
        ModernClient.post(ModernClient.opts(origins: :any), "tools/list", %{},
          headers: [{"origin", "https://evil.example"}]
        )

      assert conn.status == 200
    end

    test "the scope function fills the context", %{opts: _} do
      opts = ModernClient.opts(scope: fn conn -> conn.assigns[:who] end)

      conn =
        conn(
          :post,
          "/mcp",
          JSON.encode!(
            Sake.JSONRPC.request(1, "tools/call", %{
              "name" => "echo",
              "arguments" => %{"text" => "x"},
              "_meta" => %{
                "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities" => %{}
              }
            })
          )
        )

      conn =
        conn
        |> assign(:who, :me)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", "2026-07-28")
        |> put_req_header("mcp-method", "tools/call")
        |> put_req_header("mcp-name", "echo")
        |> Sake.Plug.call(opts)

      assert conn.status == 200
    end

    test "GET and DELETE without a session are 405", %{opts: opts} do
      assert Sake.Plug.call(conn(:get, "/mcp"), opts).status == 405
      assert Sake.Plug.call(conn(:delete, "/mcp"), opts).status == 405
    end

    test "telemetry", %{opts: opts} do
      :telemetry.attach(
        "t",
        [:sake, :server, :request, :stop],
        fn _e, _m, meta, pid -> send(pid, {:stop, meta}) end,
        self()
      )

      ModernClient.post(opts, "tools/call", %{"name" => "echo", "arguments" => %{"text" => "x"}})

      assert_receive {:stop,
                      %{
                        method: "tools/call",
                        component: "echo",
                        era: :modern,
                        protocol_version: "2026-07-28",
                        client_name: "test"
                      }}

      :telemetry.detach("t")
    end
  end

  describe "legacy POST" do
    test "initialize, session, tools/call, renewal not needed", %{opts: opts} do
      session = LegacyClient.initialize(opts, "2025-06-18", %{"elicitation" => %{}})
      assert session.revision == "2025-06-18"
      assert session.result["capabilities"]["tools"]

      assert {:ok, %{revision: "2025-06-18", capabilities: %{"elicitation" => %{}}}} =
               Sake.Server.Session.verify(ModernClient.secret(), session.id)

      # The session declares the `elicitation` capability, so this
      # tools/call streams (legacy elicitation may need the open channel).
      conn =
        LegacyClient.post(opts, session, "tools/call", %{
          "name" => "echo",
          "arguments" => %{"text" => "hi"}
        })

      assert conn.status == 200
      assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
      assert [%{"result" => result}] = ModernClient.events(conn.resp_body)
      assert %{"content" => [%{"text" => "hi"}]} = result
      refute Map.has_key?(result, "resultType")
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    test "2025-03-26 without the header, with a batch", %{opts: opts} do
      session = LegacyClient.initialize(opts, "2025-03-26")
      assert session.revision == "2025-03-26"
      conn = LegacyClient.post(opts, session, "tools/list")
      assert conn.status == 200

      batch = [
        Sake.JSONRPC.request(1, "ping"),
        Sake.JSONRPC.request(2, "tools/list"),
        Sake.JSONRPC.notification("notifications/initialized")
      ]

      conn = LegacyClient.raw(opts, session.id, batch, [])
      assert conn.status == 200

      assert [%{"id" => 1, "result" => %{}}, %{"id" => 2, "result" => %{"tools" => _}}] =
               LegacyClient.json(conn)

      conn =
        LegacyClient.raw(
          opts,
          session.id,
          [Sake.JSONRPC.notification("notifications/initialized")],
          []
        )

      assert conn.status == 202
    end

    test "batches are rejected from 2025-06-18", %{opts: opts} do
      session = LegacyClient.initialize(opts, "2025-06-18")

      conn =
        LegacyClient.raw(opts, session.id, [Sake.JSONRPC.request(1, "ping")],
          header: "2025-06-18"
        )

      assert conn.status == 400
    end

    test "missing or bad session, unknown version, initialize for a modern version", %{opts: opts} do
      conn =
        LegacyClient.raw(opts, nil, Sake.JSONRPC.request(1, "tools/list"), header: "2025-06-18")

      assert conn.status == 404 and
               LegacyClient.json(conn)["error"]["message"] == "Unknown session"

      conn =
        LegacyClient.raw(opts, "bogus", Sake.JSONRPC.request(1, "tools/list"),
          header: "2025-06-18"
        )

      assert conn.status == 404
      conn = LegacyClient.raw(opts, nil, Sake.JSONRPC.request(1, "tools/list"), [])
      assert conn.status == 404

      conn =
        LegacyClient.raw(
          opts,
          nil,
          Sake.JSONRPC.request(1, "initialize", %{
            "protocolVersion" => "2026-07-28",
            "capabilities" => %{}
          }),
          []
        )

      assert conn.status == 200 and
               LegacyClient.json(conn)["result"]["protocolVersion"] == "2025-11-25"
    end

    test "DELETE with a session is 204, session ignored on modern requests", %{opts: opts} do
      session = LegacyClient.initialize(opts)

      conn =
        conn(:delete, "/mcp")
        |> put_req_header("mcp-session-id", session.id)
        |> Sake.Plug.call(opts)

      assert conn.status == 204
      conn = ModernClient.post(opts, "tools/list", %{}, headers: [{"mcp-session-id", session.id}])
      assert conn.status == 200 and get_resp_header(conn, "mcp-session-id") == []
    end

    test "legacy resource not found is -32002 and forbidden is 403", %{opts: opts} do
      session = LegacyClient.initialize(opts)
      conn = LegacyClient.post(opts, session, "resources/read", %{"uri" => "issue://9"})
      assert conn.status == 200 and LegacyClient.json(conn)["error"]["code"] == -32_002
    end

    test "initialize with a modern version header still opens a legacy session", %{opts: opts} do
      conn =
        LegacyClient.raw(
          opts,
          nil,
          Sake.JSONRPC.request(1, "initialize", %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{}
          }),
          header: "2026-07-28"
        )

      assert conn.status == 200
      assert LegacyClient.json(conn)["result"]["protocolVersion"] == "2025-06-18"
      assert [_session] = get_resp_header(conn, "mcp-session-id")

      conn =
        LegacyClient.raw(
          opts,
          nil,
          Sake.JSONRPC.request(1, "initialize", %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{}
          }),
          header: "2099-01-01"
        )

      assert conn.status == 400 and LegacyClient.json(conn)["error"]["code"] == -32_022
    end
  end
end
