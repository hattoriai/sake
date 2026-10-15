defmodule Sake.StdioTest do
  use ExUnit.Case, async: false

  alias SakeTest.Pipe

  defmodule Whoami do
    use Sake.Tool, name: "whoami", description: "Returns the principal"

    @impl true
    def execute(_args, ctx), do: {:ok, inspect(ctx.scope)}
  end

  defmodule Chatty do
    use Sake.Tool, name: "chatty", description: "Logs at two levels"

    @impl true
    def execute(_args, ctx) do
      Sake.Progress.log(ctx, :debug, "debug")
      Sake.Progress.log(ctx, :warning, "warning")
      {:ok, "done"}
    end
  end

  defmodule Server do
    use Sake.Server, name: "stdio-test", version: "1.0.0"

    tools [
      SakeDev.Tools.Echo,
      SakeDev.Tools.Slow,
      SakeDev.Tools.Confirm,
      Sake.StdioTest.Whoami,
      Sake.StdioTest.Chatty
    ]

    resources [SakeDev.Resources.Issue]
  end

  @modern "2026-07-28"

  setup do
    pipe = Pipe.start()
    %{pipe: pipe}
  end

  defp serve(pipe, opts \\ []) do
    test = self()

    {:ok, pid} =
      Task.start_link(fn ->
        Sake.Stdio.run(Server, Keyword.merge([input: pipe, output: pipe], opts))
        send(test, :stopped)
      end)

    pid
  end

  defp modern(id, method, params \\ %{}, meta \\ %{}) do
    Sake.JSONRPC.request(
      id,
      method,
      Map.put(
        params,
        "_meta",
        Map.merge(
          %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          },
          meta
        )
      )
    )
  end

  defp initialize(pipe, revision \\ "2025-11-25", capabilities \\ %{}) do
    Pipe.push(
      pipe,
      Sake.JSONRPC.request(0, "initialize", %{
        "protocolVersion" => revision,
        "capabilities" => capabilities,
        "clientInfo" => %{"name" => "stdio-test", "version" => "0"}
      })
    )

    assert %{"id" => 0, "result" => %{"protocolVersion" => ^revision}} = recv(pipe)
    Pipe.push(pipe, Sake.JSONRPC.notification("notifications/initialized"))
  end

  defp call(id, name, arguments, meta \\ nil) do
    params = %{"name" => name, "arguments" => arguments}
    params = if meta, do: Map.put(params, "_meta", meta), else: params
    Sake.JSONRPC.request(id, "tools/call", params)
  end

  defp recv(pipe) do
    assert_receive {:pipe, ^pipe, message}, 2_000
    message
  end

  describe "modern" do
    test "discover, list and call, with every request's metadata inline", %{pipe: pipe} do
      serve(pipe)
      Pipe.push(pipe, modern(1, "server/discover"))

      assert %{"id" => 1, "result" => %{"supportedVersions" => [@modern | _]} = result} =
               recv(pipe)

      assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "stdio-test"

      Pipe.push(pipe, modern(2, "tools/list"))
      assert %{"id" => 2, "result" => %{"tools" => tools}} = recv(pipe)
      assert "echo" in Enum.map(tools, & &1["name"])

      Pipe.push(
        pipe,
        modern(3, "tools/call", %{"name" => "echo", "arguments" => %{"text" => "hé"}})
      )

      assert %{
               "id" => 3,
               "result" => %{"content" => [%{"text" => "hé"}], "resultType" => "complete"}
             } =
               recv(pipe)
    end

    test "the _meta checks of the HTTP endpoint apply", %{pipe: pipe} do
      serve(pipe)

      Pipe.push(
        pipe,
        modern(1, "tools/list", %{}, %{"io.modelcontextprotocol/clientCapabilities" => nil})
      )

      assert %{"id" => 1, "error" => %{"code" => -32_602}} = recv(pipe)

      Pipe.push(
        pipe,
        modern(2, "tools/list", %{}, %{"io.modelcontextprotocol/logLevel" => "loud"})
      )

      assert %{"id" => 2, "error" => %{"code" => -32_602, "message" => "Unknown log level"}} =
               recv(pipe)

      Pipe.push(
        pipe,
        modern(3, "tools/list", %{}, %{"io.modelcontextprotocol/protocolVersion" => "2099-01-01"})
      )

      assert %{
               "id" => 3,
               "error" => %{"code" => -32_022, "data" => %{"requested" => "2099-01-01"}}
             } =
               recv(pipe)

      Pipe.push(pipe, Sake.JSONRPC.request(4, "tools/list", %{}))

      assert %{"id" => 4, "error" => %{"code" => -32_600, "message" => "Not initialized"}} =
               recv(pipe)
    end

    test "elicitation is an input_required result, answered on a retry", %{pipe: pipe} do
      serve(pipe)
      caps = %{"io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}}
      Pipe.push(pipe, modern(1, "tools/call", %{"name" => "confirm", "arguments" => %{}}, caps))

      assert %{"id" => 1, "result" => %{"resultType" => "input_required"} = result} = recv(pipe)
      assert %{"who" => %{"method" => "elicitation/create"}} = result["inputRequests"]

      Pipe.push(
        pipe,
        modern(
          2,
          "tools/call",
          %{
            "name" => "confirm",
            "arguments" => %{},
            "requestState" => result["requestState"],
            "inputResponses" => %{
              "who" => %{"action" => "accept", "content" => %{"name" => "Ana"}}
            }
          },
          caps
        )
      )

      assert %{"id" => 2, "result" => %{"content" => [%{"text" => "Hello, Ana!"}]}} = recv(pipe)
    end

    test "progress and log notifications carry the request's token and honour its level", %{
      pipe: pipe
    } do
      serve(pipe)

      Pipe.push(
        pipe,
        modern(
          1,
          "tools/call",
          %{"name" => "slow", "arguments" => %{"n" => 2, "delay_ms" => 0}},
          %{"progressToken" => "p1"}
        )
      )

      assert %{
               "method" => "notifications/progress",
               "params" => %{"progressToken" => "p1", "progress" => 1, "total" => 2}
             } = recv(pipe)

      assert %{"method" => "notifications/progress", "params" => %{"progress" => 2}} = recv(pipe)
      assert %{"id" => 1, "result" => %{"content" => [%{"text" => "counted to 2"}]}} = recv(pipe)

      Pipe.push(
        pipe,
        modern(2, "tools/call", %{"name" => "chatty", "arguments" => %{}}, %{
          "io.modelcontextprotocol/logLevel" => "info"
        })
      )

      assert %{"method" => "notifications/message", "params" => %{"level" => "warning"}} =
               recv(pipe)

      assert %{"id" => 2, "result" => _} = recv(pipe)
    end

    test "subscriptions/listen: acknowledged, then tagged notifications until cancelled", %{
      pipe: pipe
    } do
      serve(pipe)

      Pipe.push(
        pipe,
        modern(7, "subscriptions/listen", %{
          "notifications" => %{
            "toolsListChanged" => true,
            "promptsListChanged" => false,
            "resourceSubscriptions" => ["issue://1"]
          }
        })
      )

      tag = %{"io.modelcontextprotocol/subscriptionId" => 7}

      assert %{
               "method" => "notifications/subscriptions/acknowledged",
               "params" => %{
                 "notifications" => %{
                   "toolsListChanged" => true,
                   "resourceSubscriptions" => ["issue://1"]
                 },
                 "_meta" => ^tag
               }
             } = recv(pipe)

      Sake.Server.notify_list_changed(Server, :prompts)
      Sake.Server.notify_list_changed(Server, :tools)
      Sake.Server.resource_updated(Server, "issue://2")
      Sake.Server.resource_updated(Server, "issue://1")

      assert %{"method" => "notifications/tools/list_changed", "params" => %{"_meta" => ^tag}} =
               recv(pipe)

      assert %{
               "method" => "notifications/resources/updated",
               "params" => %{"uri" => "issue://1", "_meta" => ^tag}
             } = recv(pipe)

      Pipe.push(pipe, Sake.JSONRPC.notification("notifications/cancelled", %{"requestId" => 7}))
      Pipe.push(pipe, modern(8, "tools/list"))
      assert %{"id" => 8} = recv(pipe)

      Sake.Server.notify_list_changed(Server, :tools)
      refute_receive {:pipe, ^pipe, _}, 100
    end

    test "a listen stream still open when input closes ends with its result", %{pipe: pipe} do
      serve(pipe)
      Pipe.push(pipe, modern("s", "subscriptions/listen", %{"notifications" => %{}}))
      assert %{"method" => "notifications/subscriptions/acknowledged"} = recv(pipe)

      Pipe.close(pipe)

      assert %{
               "id" => "s",
               "result" => %{
                 "resultType" => "complete",
                 "_meta" => %{"io.modelcontextprotocol/subscriptionId" => "s"}
               }
             } = recv(pipe)

      assert_receive :stopped, 1_000
    end
  end

  describe "legacy" do
    test "initialize, then requests without _meta belong to the session", %{pipe: pipe} do
      serve(pipe)
      initialize(pipe)

      Pipe.push(pipe, Sake.JSONRPC.request(1, "ping"))
      assert %{"id" => 1, "result" => %{}} = recv(pipe)

      Pipe.push(pipe, call(2, "echo", %{"text" => "hi"}))
      assert %{"id" => 2, "result" => %{"content" => [%{"text" => "hi"}]} = result} = recv(pipe)
      refute Map.has_key?(result, "resultType")

      # A modern request is still served alongside the session.
      Pipe.push(pipe, modern(3, "tools/list"))
      assert %{"id" => 3, "result" => %{"resultType" => "complete"}} = recv(pipe)
    end

    test "elicitation: the server asks on stdout and the handler waits for the answer", %{
      pipe: pipe
    } do
      serve(pipe)
      initialize(pipe, "2025-11-25", %{"elicitation" => %{}})
      Pipe.push(pipe, call(1, "confirm", %{"greeting" => "Hi"}))

      assert %{"id" => ask, "method" => "elicitation/create", "params" => params} = recv(pipe)
      assert params["_meta"]["ai.hattori.sake/key"] == "who"

      Pipe.push(
        pipe,
        Sake.JSONRPC.result(ask, %{"action" => "accept", "content" => %{"name" => "Ana"}})
      )

      assert %{"id" => 1, "result" => %{"content" => [%{"text" => "Hi, Ana!"}]}} = recv(pipe)
    end

    test "logging/setLevel sets the level of later requests", %{pipe: pipe} do
      serve(pipe)
      initialize(pipe)

      Pipe.push(pipe, call(1, "chatty", %{}))
      assert %{"id" => 1} = recv(pipe)

      Pipe.push(pipe, Sake.JSONRPC.request(2, "logging/setLevel", %{"level" => "nope"}))
      assert %{"id" => 2, "error" => %{"code" => -32_602}} = recv(pipe)

      Pipe.push(pipe, Sake.JSONRPC.request(3, "logging/setLevel", %{"level" => "debug"}))
      assert %{"id" => 3, "result" => %{}} = recv(pipe)

      Pipe.push(pipe, call(4, "chatty", %{}))

      assert %{"method" => "notifications/message", "params" => %{"level" => "debug"}} =
               recv(pipe)

      assert %{"method" => "notifications/message", "params" => %{"level" => "warning"}} =
               recv(pipe)

      assert %{"id" => 4} = recv(pipe)
    end

    test "resources/subscribe: updated notifications for subscribed URIs, list changes for all",
         %{pipe: pipe} do
      serve(pipe)
      initialize(pipe)

      Pipe.push(pipe, Sake.JSONRPC.request(1, "resources/subscribe", %{"uri" => "issue://1"}))
      assert %{"id" => 1, "result" => %{}} = recv(pipe)

      Sake.Server.resource_updated(Server, "issue://2")
      Sake.Server.resource_updated(Server, "issue://1")

      assert %{"method" => "notifications/resources/updated", "params" => %{"uri" => "issue://1"}} =
               recv(pipe)

      Sake.Server.notify_list_changed(Server, :tools)
      assert %{"method" => "notifications/tools/list_changed"} = recv(pipe)

      Pipe.push(pipe, Sake.JSONRPC.request(2, "resources/unsubscribe", %{"uri" => "issue://1"}))
      assert %{"id" => 2, "result" => %{}} = recv(pipe)

      Sake.Server.resource_updated(Server, "issue://1")
      refute_receive {:pipe, ^pipe, _}, 100
    end

    test "a 2025-03-26 session takes batches; later revisions do not", %{pipe: pipe} do
      serve(pipe)
      initialize(pipe, "2025-03-26")

      Pipe.push(pipe, [
        Sake.JSONRPC.request(1, "ping"),
        Sake.JSONRPC.notification("notifications/progress", %{}),
        call(2, "echo", %{"text" => "b"})
      ])

      assert [%{"id" => 1}, %{"id" => 2, "result" => %{"content" => [%{"text" => "b"}]}}] =
               recv(pipe)

      initialize(pipe, "2025-06-18")
      Pipe.push(pipe, [Sake.JSONRPC.request(3, "ping")])
      assert %{"id" => nil, "error" => %{"code" => -32_600}} = recv(pipe)
    end
  end

  describe "requests" do
    test "run concurrently and answer out of order", %{pipe: pipe} do
      serve(pipe)

      Pipe.push(
        pipe,
        modern(1, "tools/call", %{"name" => "slow", "arguments" => %{"n" => 1, "delay_ms" => 200}})
      )

      Pipe.push(
        pipe,
        modern(2, "tools/call", %{"name" => "echo", "arguments" => %{"text" => "x"}})
      )

      assert %{"id" => 2} = recv(pipe)
      assert %{"id" => 1} = recv(pipe)
    end

    test "notifications/cancelled stops a request and suppresses its response", %{pipe: pipe} do
      ref = make_ref()
      test = self()

      :telemetry.attach(
        inspect(ref),
        [:sake, :server, :request, :stop],
        fn _event, _measurements, meta, _ -> send(test, {ref, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(inspect(ref)) end)

      serve(pipe)

      Pipe.push(
        pipe,
        modern(
          "c",
          "tools/call",
          %{"name" => "slow", "arguments" => %{"n" => 5, "delay_ms" => 100}},
          %{"progressToken" => "t"}
        )
      )

      assert %{"method" => "notifications/progress"} = recv(pipe)
      Pipe.push(pipe, Sake.JSONRPC.notification("notifications/cancelled", %{"requestId" => "c"}))
      assert_receive {^ref, %{method: "tools/call", cancelled: true}}, 1_000

      # Unknown and malformed cancellations are ignored.
      Pipe.push(
        pipe,
        Sake.JSONRPC.notification("notifications/cancelled", %{"requestId" => "zz"})
      )

      Pipe.push(pipe, Sake.JSONRPC.notification("notifications/cancelled", %{}))

      Pipe.push(pipe, modern(1, "tools/list"))
      assert %{"id" => 1} = recv(pipe)
      refute_receive {:pipe, ^pipe, _}, 600
    end

    test "an id already in flight is refused", %{pipe: pipe} do
      serve(pipe)

      Pipe.push(
        pipe,
        modern(1, "tools/call", %{"name" => "slow", "arguments" => %{"n" => 1, "delay_ms" => 200}})
      )

      Pipe.push(pipe, modern(1, "tools/list"))

      assert %{"id" => 1, "error" => %{"message" => "Request id already in use"}} = recv(pipe)
      assert %{"id" => 1, "result" => %{"content" => [%{"text" => "counted to 1"}]}} = recv(pipe)
    end

    test "scope: is a value or a function evaluated per request", %{pipe: pipe} do
      serve(pipe, scope: fn -> %{user: "ana"} end)
      Pipe.push(pipe, modern(1, "tools/call", %{"name" => "whoami", "arguments" => %{}}))
      assert %{"result" => %{"content" => [%{"text" => ~s(%{user: "ana"})}]}} = recv(pipe)

      other = Pipe.start()
      serve(other, scope: :org)
      Pipe.push(other, modern(1, "tools/call", %{"name" => "whoami", "arguments" => %{}}))
      assert %{"result" => %{"content" => [%{"text" => ":org"}]}} = recv(other)
    end

    test "a scope function that raises fails its request, not the server", %{pipe: pipe} do
      calls = :counters.new(1, [])

      serve(pipe,
        scope: fn ->
          :counters.add(calls, 1, 1)
          if :counters.get(calls, 1) == 1, do: raise("no principal"), else: :ana
        end
      )

      ExUnit.CaptureLog.capture_log(fn ->
        Pipe.push(pipe, modern(1, "tools/call", %{"name" => "whoami", "arguments" => %{}}))
        assert %{"id" => 1, "error" => %{"code" => -32_603}} = recv(pipe)
      end)

      Pipe.push(pipe, modern(2, "tools/list"))
      assert %{"id" => 2, "result" => _} = recv(pipe)
    end
  end

  describe "input" do
    test "a line that is not JSON is a parse error; not JSON-RPC, an invalid request", %{
      pipe: pipe
    } do
      serve(pipe)

      Pipe.push(pipe, "{nope")
      assert %{"id" => nil, "error" => %{"code" => -32_700}} = recv(pipe)

      Pipe.push(pipe, ~s({"jsonrpc":"2.0","id":{"x":1},"method":"ping"}))
      assert %{"id" => nil, "error" => %{"code" => -32_600}} = recv(pipe)

      Pipe.push(pipe, modern(1, "tools/call", %{"name" => "echo", "arguments" => "x"}))

      assert %{
               "id" => 1,
               "error" => %{"code" => -32_602, "message" => "arguments must be an object"}
             } =
               recv(pipe)

      Pipe.push(pipe, Sake.JSONRPC.request(2, "tools/list", %{"_meta" => 3}))
      assert %{"id" => 2, "error" => %{"code" => -32_602}} = recv(pipe)

      # Blank lines are skipped; the server is still serving.
      Pipe.push(pipe, "")
      Pipe.push(pipe, modern(3, "tools/list"))
      assert %{"id" => 3, "result" => _} = recv(pipe)
    end
  end

  describe "end of input" do
    test "requests in flight finish, then the server stops", %{pipe: pipe} do
      serve(pipe)

      Pipe.push(
        pipe,
        modern(1, "tools/call", %{"name" => "slow", "arguments" => %{"n" => 1, "delay_ms" => 100}})
      )

      Pipe.close(pipe)

      assert %{"id" => 1, "result" => _} = recv(pipe)
      assert_receive :stopped, 1_000
    end

    test "a request still running after the grace period is dropped", %{pipe: pipe} do
      serve(pipe, grace: 50)

      Pipe.push(
        pipe,
        modern(1, "tools/call", %{
          "name" => "slow",
          "arguments" => %{"n" => 1, "delay_ms" => 1_000}
        })
      )

      Pipe.close(pipe)

      assert_receive :stopped, 500
      refute_receive {:pipe, ^pipe, _}, 100
    end

    test "with nothing in flight, the server stops at once", %{pipe: pipe} do
      pid = serve(pipe)
      ref = Process.monitor(pid)
      Pipe.close(pipe)
      assert_receive :stopped, 500
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end
  end
end
