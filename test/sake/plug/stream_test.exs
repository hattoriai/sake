defmodule Sake.Plug.StreamTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias SakeTest.{HTTP, LegacyClient, ModernClient}

  @modern_headers [
    {"accept", "application/json, text/event-stream"},
    {"mcp-protocol-version", "2026-07-28"},
    {"mcp-method", "tools/call"},
    {"mcp-name", "slow"}
  ]

  defp modern_body(id, method, params) do
    Sake.JSONRPC.request(
      id,
      method,
      Map.put(
        params,
        "_meta",
        Map.merge(
          %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          },
          params["_meta"] || %{}
        )
      )
    )
  end

  test "a progress token makes the response an SSE stream with progress then the result (Plug.Test)" do
    conn =
      ModernClient.post(ModernClient.opts(), "tools/call", %{
        "name" => "slow",
        "arguments" => %{"n" => 2, "delay_ms" => 0},
        "_meta" => %{"progressToken" => "p1"}
      })

    assert conn.status == 200
    assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    events = ModernClient.events(conn.resp_body)

    assert [
             %{
               "method" => "notifications/progress",
               "params" => %{"progressToken" => "p1", "progress" => 1, "total" => 2}
             },
             %{"method" => "notifications/progress", "params" => %{"progress" => 2}},
             %{"id" => 1, "result" => %{"content" => [%{"text" => "counted to 2"}]}}
           ] = events
  end

  test "a stream: true tool streams even without a token; a plain tool does not" do
    conn =
      ModernClient.post(ModernClient.opts(), "tools/call", %{
        "name" => "slow",
        "arguments" => %{"n" => 1, "delay_ms" => 0}
      })

    assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")

    conn =
      ModernClient.post(ModernClient.opts(), "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "x"}
      })

    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
  end

  test "log messages flow only when the request set a log level" do
    defmodule Chatty do
      use Sake.Tool, name: "chatty", description: "logs", stream: true

      def execute(_, ctx) do
        Sake.Progress.log(ctx, :info, %{"step" => 1})
        {:ok, "done"}
      end
    end

    defmodule ChattyServer do
      use Sake.Server, name: "c", version: "1"
      tools [Chatty]
    end

    opts = ModernClient.opts(server: ChattyServer)

    conn =
      ModernClient.post(opts, "tools/call", %{"name" => "chatty", "arguments" => %{}},
        meta: %{"io.modelcontextprotocol/logLevel" => "info"}
      )

    assert [
             %{
               "method" => "notifications/message",
               "params" => %{"level" => "info", "data" => %{"step" => 1}}
             },
             %{"result" => _}
           ] = ModernClient.events(conn.resp_body)

    conn = ModernClient.post(opts, "tools/call", %{"name" => "chatty", "arguments" => %{}})
    assert [%{"result" => _}] = ModernClient.events(conn.resp_body)
  end

  test "keep-alive comments and a real HTTP stream" do
    url = HTTP.start()

    body =
      modern_body(7, "tools/call", %{
        "name" => "slow",
        "arguments" => %{"n" => 2, "delay_ms" => 50},
        "_meta" => %{"progressToken" => 1}
      })

    assert {:done, 200, events} =
             HTTP.sse(url <> "/mcp", body, @modern_headers, fn _ -> false end)

    assert Enum.count(events, &(&1["method"] == "notifications/progress")) == 2
    assert List.last(events)["id"] == 7
  end

  test "subscriptions/listen acknowledges, delivers list changes and resource updates, tags the subscription id" do
    url = HTTP.start()

    headers = [
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", "subscriptions/listen"}
    ]

    body =
      modern_body("sub-1", "subscriptions/listen", %{
        "notifications" => %{
          "toolsListChanged" => true,
          "promptsListChanged" => false,
          "resourceSubscriptions" => ["issue://1"]
        }
      })

    spawn(fn ->
      Process.sleep(200)
      Sake.Server.notify_list_changed(SakeDev.Server, :tools)
      Sake.Server.notify_list_changed(SakeDev.Server, :prompts)
      Sake.Server.resource_updated(SakeDev.Server, "issue://2")
      Sake.Server.resource_updated(SakeDev.Server, "issue://1")
    end)

    assert {:ok, events} =
             HTTP.sse(url <> "/mcp", body, headers, fn events -> length(events) >= 3 end)

    assert [ack, changed, updated] = events
    assert ack["method"] == "notifications/subscriptions/acknowledged"

    assert ack["params"]["notifications"] == %{
             "toolsListChanged" => true,
             "resourceSubscriptions" => ["issue://1"]
           }

    assert ack["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == "sub-1"
    assert changed["method"] == "notifications/tools/list_changed"
    assert changed["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == "sub-1"

    assert updated == %{
             "jsonrpc" => "2.0",
             "method" => "notifications/resources/updated",
             "params" => %{
               "uri" => "issue://1",
               "_meta" => %{"io.modelcontextprotocol/subscriptionId" => "sub-1"}
             }
           }
  end

  defmodule Scoped do
    @moduledoc false
    # Sake.Plug behind a token carrying `scopes`, as an endpoint with
    # authorization would see it.
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(scopes),
      do: {scopes, Sake.Plug.init(server: SakeDev.Server, secret: String.duplicate("s", 64))}

    @impl true
    def call(conn, {scopes, opts}) do
      conn
      |> assign(:sake_token, %{subject_id: "alice", client_id: "test", issuer: nil})
      |> assign(:sake_scopes, scopes)
      |> Sake.Plug.call(opts)
    end
  end

  # Listens for issue://1 (which needs issues:read), dev://readme (which
  # takes no subscriptions) and x://y (which names nothing) with a token
  # carrying `scopes`, announces an update to each and then a tools list
  # change, and returns the events up to that list change.
  defp scoped_listen(scopes) do
    url = HTTP.start({Scoped, scopes})

    body =
      modern_body("sub-s", "subscriptions/listen", %{
        "notifications" => %{
          "toolsListChanged" => true,
          "resourceSubscriptions" => ["issue://1", "dev://readme", "x://y"]
        }
      })

    headers = [
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", "subscriptions/listen"}
    ]

    spawn(fn ->
      Process.sleep(200)
      Sake.Server.resource_updated(SakeDev.Server, "issue://1")
      Sake.Server.resource_updated(SakeDev.Server, "dev://readme")
      Sake.Server.resource_updated(SakeDev.Server, "x://y")
      Sake.Server.notify_list_changed(SakeDev.Server, :tools)
    end)

    assert {:ok, events} =
             HTTP.sse(url <> "/mcp", body, headers, fn events ->
               List.last(events)["method"] == "notifications/tools/list_changed"
             end)

    events
  end

  test "subscriptions/listen follows a resource the token's scopes allow, and only a subscribable one" do
    assert [ack, updated, %{"method" => "notifications/tools/list_changed"}] =
             scoped_listen(["issues:read"])

    assert ack["params"]["notifications"] == %{
             "toolsListChanged" => true,
             "resourceSubscriptions" => ["issue://1"]
           }

    assert updated["method"] == "notifications/resources/updated"
    assert updated["params"]["uri"] == "issue://1"
  end

  test "subscriptions/listen does not follow a resource the token's scopes do not allow" do
    assert [ack, %{"method" => "notifications/tools/list_changed"}] = scoped_listen([])
    assert ack["params"]["notifications"] == %{"toolsListChanged" => true}
  end

  test "the legacy GET stream carries list changes and subscribed resource updates" do
    url = HTTP.start()
    session = LegacyClient.initialize(ModernClient.opts(), "2025-06-18")
    # subscribe through a POST, then open the stream and trigger updates
    parent = self()

    task =
      Task.async(fn ->
        Req.get!(url <> "/mcp",
          headers: [
            {"accept", "text/event-stream"},
            {"mcp-session-id", session.id},
            {"mcp-protocol-version", "2025-06-18"}
          ],
          receive_timeout: 5_000,
          into: fn {:data, d}, acc ->
            send(parent, {:sse_data, d})
            {:cont, acc}
          end
        )
      end)

    Process.sleep(200)

    conn =
      LegacyClient.post(ModernClient.opts(), session, "resources/subscribe", %{
        "uri" => "issue://1"
      })

    assert conn.status == 200
    Process.sleep(100)
    Sake.Server.notify_list_changed(SakeDev.Server, :tools)
    Sake.Server.resource_updated(SakeDev.Server, "issue://2")
    Sake.Server.resource_updated(SakeDev.Server, "issue://1")

    data = receive_all("", 1_000)
    Task.shutdown(task, :brutal_kill)
    events = ModernClient.events(data)

    assert Enum.map(events, & &1["method"]) == [
             "notifications/tools/list_changed",
             "notifications/resources/updated"
           ]

    assert List.last(events)["params"] == %{"uri" => "issue://1"}
  end

  test "a renewed session ID keeps the session: its GET stream still gets the updates" do
    url = HTTP.start()
    session = LegacyClient.initialize(ModernClient.opts(), "2025-06-18")
    parent = self()

    task =
      Task.async(fn ->
        Req.get!(url <> "/mcp",
          headers: [
            {"accept", "text/event-stream"},
            {"mcp-session-id", session.id},
            {"mcp-protocol-version", "2025-06-18"}
          ],
          receive_timeout: 5_000,
          into: fn {:data, d}, acc ->
            send(parent, {:sse_data, d})
            {:cont, acc}
          end
        )
      end)

    Process.sleep(200)

    # setLevel renews the ID; the client carries on with the new one
    conn =
      LegacyClient.post(ModernClient.opts(), session, "logging/setLevel", %{"level" => "info"})

    assert conn.status == 200
    [renewed] = get_resp_header(conn, "mcp-session-id")
    assert renewed != session.id
    renewed_session = %{session | id: renewed}

    conn =
      LegacyClient.post(ModernClient.opts(), renewed_session, "resources/subscribe", %{
        "uri" => "issue://1"
      })

    assert conn.status == 200
    Process.sleep(100)
    Sake.Server.resource_updated(SakeDev.Server, "issue://1")

    data = receive_all("", 1_000)
    Task.shutdown(task, :brutal_kill)

    assert [%{"method" => "notifications/resources/updated", "params" => %{"uri" => "issue://1"}}] =
             ModernClient.events(data)
  end

  test "an unknown log level is refused on both eras" do
    session = LegacyClient.initialize(ModernClient.opts(), "2025-06-18")

    conn =
      LegacyClient.post(ModernClient.opts(), session, "logging/setLevel", %{"level" => "loud"})

    assert %{"error" => %{"code" => -32_602}} = LegacyClient.json(conn)
    assert get_resp_header(conn, "mcp-session-id") == []

    conn =
      ModernClient.post(ModernClient.opts(), "tools/list", %{},
        meta: %{"io.modelcontextprotocol/logLevel" => "not_an_existing_atom_level"}
      )

    assert conn.status == 400

    assert %{"error" => %{"code" => -32_602, "message" => "Unknown log level"}} =
             ModernClient.json(conn)

    conn =
      ModernClient.post(ModernClient.opts(), "tools/list", %{},
        meta: %{"io.modelcontextprotocol/logLevel" => "warning"}
      )

    assert conn.status == 200
  end

  defp receive_all(acc, timeout) do
    receive do
      {:sse_data, d} -> receive_all(acc <> d, timeout)
    after
      timeout -> acc
    end
  end

  test "a closed client stream kills the handler" do
    url = HTTP.start()

    :telemetry.attach(
      "kill",
      [:sake, :server, :request, :stop],
      fn _e, _m, meta, pid -> send(pid, {:stopped, meta}) end,
      self()
    )

    body =
      modern_body(1, "tools/call", %{
        "name" => "slow",
        "arguments" => %{"n" => 100, "delay_ms" => 50},
        "_meta" => %{"progressToken" => 1}
      })

    assert {:ok, _} =
             HTTP.sse(url <> "/mcp", body, @modern_headers, fn events -> events != [] end)

    assert_receive {:stopped, %{cancelled: true}}, 2_000
    :telemetry.detach("kill")
  end

  test "a raising handler on a stream yields an error response and keeps the connection" do
    defmodule Boom do
      use Sake.Tool, name: "boom", description: "raises", stream: true
      def execute(_, _), do: raise("kaboom")
    end

    defmodule BoomServer do
      use Sake.Server, name: "b", version: "1"
      tools [Boom]
    end

    conn =
      ModernClient.post(
        ModernClient.opts(server: BoomServer, reraise: true),
        "tools/call",
        %{"name" => "boom", "arguments" => %{}}
      )

    assert conn.status == 200

    assert [
             %{
               "id" => 1,
               "error" => %{
                 "code" => -32_603,
                 "message" => "The request failed.",
                 "data" => %{"errorId" => _}
               }
             }
           ] =
             ModernClient.events(conn.resp_body)

    refute conn.resp_body =~ "kaboom"
  end

  test "stopping the stream supervisor ends every open listen stream with its result" do
    url = HTTP.start()

    headers = [
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", "subscriptions/listen"}
    ]

    body =
      modern_body("sub-9", "subscriptions/listen", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    on_exit(fn -> Supervisor.restart_child(SakeTest.Supervisor, Sake.Plug.Streams) end)

    spawn(fn ->
      Process.sleep(200)
      :ok = Supervisor.terminate_child(SakeTest.Supervisor, Sake.Plug.Streams)
    end)

    assert {:done, 200, [ack, done]} = HTTP.sse(url <> "/mcp", body, headers, fn _ -> false end)
    assert ack["method"] == "notifications/subscriptions/acknowledged"

    assert %{
             "id" => "sub-9",
             "result" => %{
               "resultType" => "complete",
               "_meta" => %{"io.modelcontextprotocol/subscriptionId" => "sub-9"}
             }
           } = done
  end

  test "deliver_response raises a clear error when the registry is not running" do
    Supervisor.terminate_child(SakeTest.Supervisor, Sake.Plug.Streams)

    on_exit(fn ->
      Supervisor.restart_child(SakeTest.Supervisor, Sake.Plug.Streams)
    end)

    assert_raise RuntimeError, ~r/Sake.Plug.Streams is not running/, fn ->
      Sake.Plug.Streams.deliver_response("x", {:ok, %{}})
    end
  end
end
