defmodule Sake.Plug.StreamTest do
  use ExUnit.Case, async: false
  import Plug.Test
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
end
