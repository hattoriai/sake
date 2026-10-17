defmodule Sake.TestTest do
  use ExUnit.Case, async: true

  import Sake.Test

  alias Sake.Auth.Challenge
  alias Sake.Client.ToolResult

  defmodule Whoami do
    use Sake.Tool, name: "whoami", description: "Says who is calling", scope: "issues:read"

    @impl true
    def execute(%{}, ctx) do
      token = ctx.token || %{subject_id: nil, client_id: nil}

      {:ok,
       %{
         scope: inspect(ctx.scope),
         subject: token.subject_id,
         client: token.client_id,
         scopes: ctx.scopes,
         era: ctx.era,
         version: ctx.protocol_version
       }}
    end
  end

  defmodule Boom do
    use Sake.Tool, name: "boom", description: "Raises"

    @impl true
    def execute(%{}, _ctx), do: raise(ArgumentError, "boom")
  end

  defmodule Wait do
    # A task that waits for the test to let it finish, so the test decides
    # when it ends.
    use Sake.Tool, name: "wait", description: "Waits for a message, as a task", task: :optional
    arg :pid, :string, required: true

    @impl true
    def execute(%{pid: pid}, _ctx) do
      pid = pid |> Base.decode64!() |> :erlang.binary_to_term()
      send(pid, {:waiting, self()})

      receive do
        :finish -> {:ok, "Finished."}
      after
        5_000 -> {:error, "Never finished."}
      end
    end
  end

  defmodule Changes do
    use Sake.Tool, name: "changes", description: "Announces changes"

    @impl true
    def execute(%{}, ctx) do
      Sake.Server.notify_list_changed(ctx.server, :tools)
      Sake.Server.resource_updated(ctx.server, "issue://1")
      {:ok, "Announced."}
    end
  end

  defmodule Server do
    use Sake.Server, name: "test-server", version: "1"
    scope "issues:read", "Read issues"
    scope "issues:write", "Change issues"

    tools [
      Whoami,
      Boom,
      Wait,
      Changes,
      SakeDev.Tools.Echo,
      SakeDev.Tools.Add,
      SakeDev.Tools.Slow,
      SakeDev.Tools.Confirm,
      SakeDev.Tools.Summarize,
      SakeDev.Tools.Roots,
      SakeDev.Tools.Export,
      SakeDev.Tools.IssueBoard,
      SakeDev.Tools.IssueDetails,
      SakeDev.Conformance.Tools.TestLoggingTool
    ]

    resources [SakeDev.Resources.Readme, SakeDev.Resources.Issue, SakeDev.UI.IssueBoard]
    prompts [SakeDev.Prompts.Triage]
  end

  defp pid_arg, do: self() |> :erlang.term_to_binary() |> Base.encode64()

  for era <- [:modern, :legacy] do
    describe "#{era}" do
      @era era

      test "every call goes through the server's own dispatchers" do
        client = connect(Server, era: @era)
        assert session(client).era == @era
        assert session(client).server_info["name"] == "test-server"

        assert {:ok, tools} = list_tools(client)
        assert "echo" in Enum.map(tools, & &1.name)
        refute "issue_details" in Enum.map(tools, & &1.name)

        assert {:ok, %ToolResult{text: "hi", is_error: false}} =
                 call_tool(client, "echo", %{"text" => "hi"})

        # The structured content crossed as JSON: its keys are strings.
        assert {:ok, %ToolResult{structured: %{"sum" => 3}}} =
                 call_tool(client, "add", %{"a" => 1, "b" => 2})

        assert {:ok, %ToolResult{is_error: true, text: "Invalid arguments: " <> _}} =
                 call_tool(client, "add", %{"a" => "x"})

        assert {:error, {:rpc, %{"code" => -32_602, "message" => "Unknown tool: nope"}}} =
                 call_tool(client, "nope")

        assert {:ok, resources} = list_resources(client)
        assert Enum.map(resources, & &1["uri"]) == ["dev://readme", "issue://1", "issue://2"]
        assert {:ok, [%{uri: "issue://1", text: text}]} = read_resource(client, "issue://1")
        assert JSON.decode!(text)["title"] == "Login fails on Safari"

        assert {:error, {:rpc, %{"data" => %{"uri" => "issue://9"}}}} =
                 read_resource(client, "issue://9")

        assert {:ok, [%{"uriTemplate" => "issue://{id}"}]} = list_resource_templates(client)

        assert {:ok, [%{"name" => "triage"}]} = list_prompts(client)
        assert {:ok, %{"messages" => [_]}} = get_prompt(client, "triage", %{"id" => "1"})
        assert {:error, {:rpc, %{"code" => -32_602}}} = get_prompt(client, "triage")

        assert {:ok, %{"values" => ["direct"]}} =
                 complete(client, {:prompt, "triage"}, "tone", "d")

        assert :ok = ping(client)
        assert :ok = close(client)
        refute Process.alive?(client.pid)
      end

      test "without scopes: there is no token, and nothing is gated" do
        client = connect(Server, era: @era, scope: %{user: "ana"})

        assert {:ok, %{structured: whoami}} = call_tool(client, "whoami")

        assert whoami == %{
                 "scope" => ~s(%{user: "ana"}),
                 "subject" => nil,
                 "client" => nil,
                 "scopes" => [],
                 "era" => to_string(@era),
                 "version" => session(client).revision
               }

        assert {:ok, %{text: "counted to 1"}} = call_tool(client, "slow", %{"n" => 1})
      end

      test "with scopes: a token, and the real scope checks" do
        client = connect(Server, era: @era, scope: %{user: "ana"}, scopes: ["issues:read"])

        assert {:ok, %{structured: %{"scopes" => ["issues:read"], "subject" => subject}}} =
                 call_tool(client, "whoami")

        assert "sake-test:" <> _ = subject
        assert {:ok, tools} = list_tools(client)
        assert "whoami" in Enum.map(tools, & &1.name)
        refute "slow" in Enum.map(tools, & &1.name)

        assert {:error, {:insufficient_scope, %Challenge{scope: ["issues:write"]}}} =
                 call_tool(client, "slow", %{"n" => 1})

        client = connect(Server, era: @era, scopes: [])

        assert {:error, {:insufficient_scope, %Challenge{error: "insufficient_scope"}}} =
                 call_tool(client, "whoami")

        assert {:error, {:insufficient_scope, _}} = read_resource(client, "issue://1")
        assert {:ok, [%{"uri" => "dev://readme"}]} = list_resources(client)
      end

      test "a machine client's token has a client and no subject" do
        client =
          connect(Server,
            era: @era,
            scope: :svc,
            scopes: ["issues:read"],
            subject: nil,
            client_id: "svc"
          )

        assert {:ok, %{structured: %{"subject" => nil, "client" => "svc", "scope" => ":svc"}}} =
                 call_tool(client, "whoami")
      end

      test "elicitation is answered by on_input: and recorded" do
        client =
          connect(Server, era: @era, on_input: fn _params -> {:accept, %{"name" => "Rui"}} end)

        assert {:ok, %{text: "Hello, Rui!"}} = call_tool(client, "confirm")

        assert_asked "elicitation/create", %{"message" => "Who should be greeted?"}

        client = connect(Server, era: @era, on_input: fn _params -> :decline end)
        assert {:ok, %{text: "No greeting then."}} = call_tool(client, "confirm")
        assert_asked "elicitation/create"

        on_input = fn requests, _session ->
          Map.new(requests, fn {key, _} ->
            {key, %{"action" => "accept", "content" => %{"name" => "Ana"}}}
          end)
        end

        client = connect(Server, era: @era, on_input: on_input)
        assert {:ok, %{text: "Hi, Ana!"}} = call_tool(client, "confirm", %{"greeting" => "Hi"})
        assert_asked "elicitation/create"

        client = connect(Server, era: @era)

        assert {:ok,
                %{is_error: true, text: "This tool needs a client that supports elicitation."}} =
                 call_tool(client, "confirm")

        refute_asked "elicitation/create"
      end

      test "sampling and roots are answered by sampling: and roots: and recorded" do
        client =
          connect(Server,
            era: @era,
            sampling: fn %{"messages" => [_]} -> "A short summary." end,
            roots: [%{"uri" => "file:///work", "name" => "Work"}]
          )

        assert {:ok, %{text: "A short summary."}} =
                 call_tool(client, "summarize", %{"text" => "x"})

        assert_asked "sampling/createMessage", %{"maxTokens" => 100}
        assert {:ok, %{text: "file:///work (Work)"}} = call_tool(client, "roots")
        assert_asked "roots/list"

        client = connect(Server, era: @era)

        assert {:ok, %{is_error: true, text: "This tool needs a client that supports sampling."}} =
                 call_tool(client, "summarize", %{"text" => "x"})
      end

      test "progress and log messages are recorded" do
        client = connect(Server, era: @era)

        assert {:ok, %{text: "counted to 2"}} =
                 call_tool(client, "slow", %{"n" => 2, "delay_ms" => 0})

        assert_notification "notifications/progress", %{"progress" => 1, "total" => 2}
        assert_notification "notifications/progress", %{"progress" => 2}

        assert {:ok, _} = call_tool(client, "test_logging_tool")
        refute_notification "notifications/message"

        assert :ok = set_log_level(client, :info)
        assert {:ok, _} = call_tool(client, "test_logging_tool")

        assert_notification "notifications/message", %{"data" => "Tool execution started"}

        parent = self()
        on_notification = fn method, _params -> send(parent, {:mine, method}) end
        client = connect(Server, era: @era, log_level: "info", on_notification: on_notification)
        assert {:ok, _} = call_tool(client, "test_logging_tool")
        assert_received {:mine, "notifications/message"}
        assert_notification "notifications/message", %{"data" => "Tool execution completed"}
      end

      test "an unknown log level is refused, as in production" do
        client = connect(Server, era: @era)

        # Modern: the level travels with the call; legacy: logging/setLevel.
        refused =
          with :ok <- set_log_level(client, "loud"),
               do: call_tool(client, "echo", %{"text" => "x"})

        assert {:error, {:rpc, %{"code" => -32_602, "message" => "Unknown log level"}}} = refused
      end

      test "MCP Apps: ui: true shows the app-only tools and the UI resources" do
        client = connect(Server, era: @era, ui: true)
        assert {:ok, tools} = list_tools(client)

        assert %Sake.Tool.Spec{ui: "ui://sake-dev/issue-board", visibility: [:app]} =
                 Enum.find(tools, &(&1.name == "issue_details"))

        assert {:ok, %{structured: %{"id" => "1"}}} =
                 call_tool(client, "issue_details", %{"id" => "1"})

        assert {:ok, [%{meta: %{"ui" => _}}]} = read_resource(client, "ui://sake-dev/issue-board")

        client = connect(Server, era: @era)

        assert {:error, {:rpc, %{"code" => -32_602}}} =
                 call_tool(client, "issue_details", %{"id" => "1"})
      end

      test "an exception fails the test as it was raised, or with reraise: false is the client's error" do
        client = connect(Server, era: @era)
        assert_raise ArgumentError, "boom", fn -> call_tool(client, "boom") end

        client = connect(Server, era: @era, reraise: false)

        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{is_error: true, text: "The tool failed."}} = call_tool(client, "boom")
        end)
      end
    end
  end

  describe "tasks" do
    test "call_tool follows a task to its result, answering its questions" do
      client = connect(Server, on_input: fn _params -> {:accept, %{"format" => "csv"}} end)

      assert {:ok, %{text: "Exported 3 issues as csv."}} =
               call_tool(client, "export", %{"delay_ms" => 0})

      assert_asked "elicitation/create", %{"message" => "Which format?"}

      # A legacy session never gets a task: the same call runs synchronously.
      client =
        connect(Server, era: :legacy, on_input: fn _ -> {:accept, %{"format" => "json"}} end)

      assert {:ok, %{text: "Exported 3 issues as json."}} =
               call_tool(client, "export", %{"delay_ms" => 0})
    end

    test "call_tool_async and await_task drive a task step by step" do
      # on_input: declares elicitation; the test answers the task itself.
      client = connect(Server, on_input: fn _params -> :cancel end)

      assert {:ok, {:task, %{"taskId" => id, "status" => "working"}}} =
               call_tool_async(client, "export", %{"delay_ms" => 0})

      assert {:ok, %{"status" => "input_required", "inputRequests" => %{"format" => request}}} =
               await_task(client, id)

      assert %{"method" => "elicitation/create", "params" => %{"message" => "Which format?"}} =
               request

      assert :ok =
               update_task(client, id, %{
                 "format" => %{"action" => "accept", "content" => %{"format" => "csv"}}
               })

      assert {:ok, %{"status" => "completed", "result" => result}} = await_task(client, id)
      assert %{"content" => [%{"text" => "Exported 3 issues as csv."}]} = result
    end

    test "the client sees a task end at once, not at its next poll" do
      client = connect(Server)
      assert {:ok, {:task, task}} = call_tool_async(client, "wait", %{"pid" => pid_arg()})
      assert_receive {:waiting, worker}
      assert {:error, :timeout} = await_task(client, task, 0)

      session = session(client)
      waiter = Task.async(fn -> Sake.Client.Transport.wait(session, task, 60_000) end)
      send(worker, :finish)
      assert :ok = Task.await(waiter, 5_000)
      assert {:ok, %{"status" => "completed"}} = get_task(client, task["taskId"])
    end

    test "cancel_task cancels" do
      client = connect(Server)

      assert {:ok, {:task, %{"taskId" => id}}} =
               call_tool_async(client, "wait", %{"pid" => pid_arg()})

      assert_receive {:waiting, _worker}
      assert :ok = cancel_task(client, id)
      assert {:ok, %{"status" => "cancelled"}} = await_task(client, id)
    end

    test "a task belongs to its principal" do
      ana = connect(Server, scope: :ana)

      assert {:ok, {:task, %{"taskId" => id}}} =
               call_tool_async(ana, "wait", %{"pid" => pid_arg()})

      assert_receive {:waiting, worker}

      rui = connect(Server, scope: :rui)

      assert {:error, {:rpc, %{"message" => "Failed to retrieve task: Task not found"}}} =
               get_task(rui, id)

      assert {:error, {:rpc, %{"code" => -32_602}}} = cancel_task(rui, id)

      # Same principal, another client: the same person.
      assert {:ok, %{"status" => "working"}} = get_task(connect(Server, scope: :ana), id)

      # With tokens, the subject owns the task.
      ana = connect(Server, scope: :ana, scopes: [], subject: "u1")

      assert {:ok, {:task, %{"taskId" => id}}} =
               call_tool_async(ana, "wait", %{"pid" => pid_arg()})

      assert_receive {:waiting, worker2}

      assert {:error, {:rpc, _}} =
               get_task(connect(Server, scope: :ana, scopes: [], subject: "u2"), id)

      assert {:ok, _} = get_task(connect(Server, scope: :other, scopes: [], subject: "u1"), id)

      send(worker, :finish)
      send(worker2, :finish)
    end
  end

  describe "listen" do
    test "records the server's broadcasts, from the test and what it started" do
      :ok = listen(Server)
      client = connect(Server)

      Sake.Server.notify_list_changed(Server, :prompts)
      assert_list_changed :prompts

      assert {:ok, %{text: "Announced."}} = call_tool(client, "changes")
      assert_list_changed :tools
      assert_resource_updated "issue://1"
      refute_resource_updated "issue://2"
      refute_list_changed :resources

      # Another process, not started by this test: not this test's business.
      spawn(fn -> Sake.Server.notify_list_changed(Server, :resources) end)
      Process.sleep(20)
      refute_list_changed :resources

      # Another server's broadcasts go to that server's listeners.
      Sake.Server.notify_list_changed(SakeDev.Server, :tools)
      refute_list_changed :tools
    end

    test "takes a client, and listening twice records once" do
      client = connect(Server)
      :ok = listen(client)
      :ok = listen(client)
      Sake.Server.resource_updated(Server, "issue://2")
      assert_resource_updated "issue://2"
      refute_resource_updated "issue://2"
    end
  end

  test "the client process ends with the test's" do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:client, connect(Server)})
        receive do: (:stop -> exit(:shutdown))
      end)

    assert_receive {:client, client}
    ref = Process.monitor(client.pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, _, _}
  end

  test "session/1 hands the session to Sake.Client" do
    client = connect(Server)

    assert {:ok, %{text: "hi"}, _session} =
             Sake.Client.call_tool(session(client), "echo", %{"text" => "hi"})
  end

  test "the requests are the server's telemetry spans, on the local transport" do
    ref = make_ref()
    test = self()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [[:sake, :server, :request, :stop], [:sake, :client, :request, :stop]],
      fn event, _measurements, meta, _ -> send(test, {ref, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    client = connect(Server)
    assert {:ok, _} = call_tool(client, "echo", %{"text" => "hi"})

    assert_received {^ref, [:sake, :server, :request, :stop],
                     %{method: "tools/call", component: "echo", era: :modern}}

    assert_received {^ref, [:sake, :client, :request, :stop],
                     %{method: "tools/call", transport: :local}}
  end
end

defmodule Sake.TestSharedTest do
  # `shared: true` sees broadcasts from any process, so this test cannot
  # run beside others that broadcast for the same server.
  use ExUnit.Case, async: false

  import Sake.Test

  test "listen with shared: true records broadcasts from any process" do
    :ok = listen(Sake.TestTest.Server, shared: true)
    spawn(fn -> Sake.Server.notify_list_changed(Sake.TestTest.Server, :resources) end)
    assert_list_changed :resources
  end
end

defmodule Sake.TestPlugTest do
  # Through a plug: Sake.Plug itself, and a Phoenix endpoint with
  # authorization. Sake.Auth's configuration is the node's, so the tests
  # run alone.
  use ExUnit.Case, async: false

  import Sake.Test

  alias Sake.Auth.Challenge
  alias Sake.TestTest.Server

  @secret String.duplicate("s", 64)

  test "through Sake.Plug: the same calls, over HTTP" do
    client = connect(Server, plug: {Sake.Plug, server: Server, secret: @secret})
    assert session(client).url == "http://www.example.com/mcp"

    assert {:ok, %{text: "hi"}} = call_tool(client, "echo", %{"text" => "hi"})

    # The headers are checked: Sake.Client mirrors an argument into its
    # header once it has listed the tool, as a client does before a call.
    assert {:error, {:http, 400, %{"error" => %{"code" => -32_020}}}} =
             call_tool(client, "add", %{"a" => 1, "b" => 2, "precision" => 0})

    assert {:ok, _tools} = list_tools(client)

    assert {:ok, %{structured: %{"sum" => 3.0}}} =
             call_tool(client, "add", %{"a" => 1, "b" => 2, "precision" => 0})

    assert {:ok, %{text: "counted to 2"}} =
             call_tool(client, "slow", %{"n" => 2, "delay_ms" => 0})

    assert_notification "notifications/progress", %{"progress" => 2, "total" => 2}

    listen(Server)
    assert {:ok, _} = call_tool(client, "changes")
    assert_list_changed :tools

    client =
      connect(Server,
        plug: {Sake.Plug, server: Server, secret: @secret},
        on_input: fn _params -> {:accept, %{"name" => "Rui"}} end
      )

    assert {:ok, %{text: "Hello, Rui!"}} = call_tool(client, "confirm")
    assert_asked "elicitation/create"

    client = connect(Server, plug: {Sake.Plug, server: Server, secret: @secret}, era: :legacy)
    assert session(client).revision == "2025-11-25"
    assert {:ok, %{text: "hi"}} = call_tool(client, "echo", %{"text" => "hi"})

    # The client asks for progress, so an error comes on the call's stream,
    # as a JSON-RPC error, the same as in memory.
    client = connect(Server, plug: {Sake.Plug, server: Server, secret: @secret}, tasks: false)
    assert {:error, {:rpc, %{"code" => -32_021}}} = get_task(client, "x")
    assert {:error, {:rpc, %{"code" => -32_021}}} = get_task(connect(Server, tasks: false), "x")
  end

  test "through a Phoenix endpoint with authorization: a real bearer token" do
    start_supervised!(SakeTest.PhoenixEndpoint)

    start_supervised!(
      {Sake,
       auth: [
         subject: SakeDev.Subject,
         issuer: "http://www.example.com",
         allow_insecure: true,
         servers: [SakeDev.Server],
         resources: ["/:org/mcp"]
       ],
       secret_key_base: @secret,
       streams: false,
       tasks: false}
    )

    client =
      connect(SakeDev.Server,
        plug: SakeTest.PhoenixEndpoint,
        path: "/acme/mcp",
        scopes: ["issues:read"],
        subject: "u1"
      )

    assert {:ok, tools} = list_tools(client)
    assert "issue_board" in Enum.map(tools, & &1.name)
    refute "slow" in Enum.map(tools, & &1.name)

    assert {:error, {:insufficient_scope, %Challenge{scope: ["issues:write"]}}} =
             call_tool(client, "slow", %{"n" => 1})

    # The token is for one tenant's endpoint.
    token = access_token(subject: "u1", resource: "http://www.example.com/acme/mcp")

    assert_raise RuntimeError, ~r/unauthorized/, fn ->
      connect(SakeDev.Server,
        plug: SakeTest.PhoenixEndpoint,
        path: "/beta/mcp",
        headers: [{"authorization", "Bearer " <> token}]
      )
    end

    assert_raise RuntimeError, ~r/unauthorized/, fn ->
      connect(SakeDev.Server, plug: SakeTest.PhoenixEndpoint, path: "/acme/mcp")
    end
  end

  test "through a Phoenix endpoint that requires DPoP: a bound token, a proof per request" do
    start_supervised!(SakeTest.PhoenixEndpoint)

    start_supervised!(
      {Sake,
       auth: [
         subject: SakeDev.Subject,
         issuer: "http://www.example.com",
         allow_insecure: true,
         servers: [SakeDev.Server],
         resources: ["/:org/mcp"],
         dpop: [required: true]
       ],
       secret_key_base: @secret,
       streams: false,
       tasks: false}
    )

    client =
      connect(SakeDev.Server,
        plug: SakeTest.PhoenixEndpoint,
        path: "/acme/mcp",
        scopes: ["issues:read"],
        subject: "u1"
      )

    assert session(client).auth.token["token_type"] == "DPoP"
    assert {:ok, _tools} = list_tools(client)
    assert {:ok, %{text: "hi"}} = call_tool(client, "echo", %{"text" => "hi"})

    # A 403 comes back as it does with a bearer token: no flow runs.
    assert {:error, {:insufficient_scope, %Challenge{scheme: "DPoP", scope: ["issues:write"]}}} =
             call_tool(client, "slow", %{"n" => 1})

    # In memory there is no HTTP and no token to bind: the simulated one
    # goes straight to the scope checks, as before.
    client = connect(SakeDev.Server, scopes: ["issues:read"], subject: "u1")
    assert {:ok, %{text: "hi"}} = call_tool(client, "echo", %{"text" => "hi"})

    # A bearer token, even one the server issued, is refused.
    token = access_token(subject: "u1", resource: "http://www.example.com/acme/mcp")

    assert_raise RuntimeError, ~r/unauthorized/, fn ->
      connect(SakeDev.Server,
        plug: SakeTest.PhoenixEndpoint,
        path: "/acme/mcp",
        headers: [{"authorization", "Bearer " <> token}]
      )
    end
  end

  test "what a plug cannot take is refused up front" do
    assert_raise ArgumentError, ~r/principal/, fn ->
      connect(Server, plug: {Sake.Plug, server: Server}, scope: :ana)
    end

    assert_raise ArgumentError, ~r/in-memory/, fn ->
      connect(Server,
        plug: {Sake.Plug, server: Server},
        era: :legacy,
        on_input: fn _ -> :cancel end
      )
    end

    assert_raise ArgumentError, ~r/subject/, fn -> access_token(scopes: []) end
  end
end
