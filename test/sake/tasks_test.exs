defmodule Sake.TasksTest do
  use ExUnit.Case, async: false

  import Sake.Test

  alias Sake.Tasks.Record
  alias SakeTest.{HTTP, LegacyClient, ModernClient}

  @ext "io.modelcontextprotocol/tasks"
  @tasks %{"extensions" => %{@ext => %{}}}
  @with_input Map.merge(@tasks, %{"elicitation" => %{}})

  defmodule Plain do
    use Sake.Server, name: "plain", version: "1", extensions: %{"x.y/z" => %{"a" => 1}}
    tools [SakeDev.Tools.Echo]
  end

  defmodule Both do
    use Sake.Server, name: "both", version: "1", extensions: %{"x.y/z" => %{}}
    tools [SakeDev.Conformance.Tools.SlowCompute]
  end

  defp opts(overrides \\ []),
    do: ModernClient.opts(Keyword.merge([server: SakeDev.ConformanceServer], overrides))

  defp rpc(opts, method, params, caps, extra \\ []) do
    opts
    |> ModernClient.post(method, params, Keyword.merge([capabilities: caps], extra))
    |> ModernClient.json()
  end

  defp call(opts, name, args, caps \\ @tasks),
    do: rpc(opts, "tools/call", %{"name" => name, "arguments" => args}, caps)

  defp start(opts, name, args, caps \\ @tasks) do
    assert %{"result" => %{"resultType" => "task", "taskId" => id}} = call(opts, name, args, caps)
    id
  end

  defp get(opts, id, caps \\ @tasks), do: rpc(opts, "tasks/get", %{"taskId" => id}, caps)

  # Polls tasks/get until `done?` holds for the task.
  defp await(opts, id, done?, caps \\ @tasks, tries \\ 100) do
    %{"result" => task} = get(opts, id, caps)

    cond do
      done?.(task) ->
        task

      tries == 0 ->
        flunk("task #{id} never got there: #{inspect(task)}")

      true ->
        Process.sleep(20)
        await(opts, id, done?, caps, tries - 1)
    end
  end

  defp terminal?(task), do: task["status"] in ["completed", "failed", "cancelled"]

  describe "capabilities" do
    test "server/discover advertises the extension when a tool can run as a task" do
      assert %{"result" => %{"capabilities" => %{"extensions" => %{@ext => %{}}}}} =
               rpc(opts(), "server/discover", %{}, %{})

      assert %{
               "result" => %{"capabilities" => %{"extensions" => %{"x.y/z" => %{"a" => 1}} = ext}}
             } =
               rpc(opts(server: Plain), "server/discover", %{}, %{})

      refute Map.has_key?(ext, @ext)

      assert %{"result" => %{"capabilities" => %{"extensions" => %{"x.y/z" => %{}, @ext => %{}}}}} =
               rpc(opts(server: Both), "server/discover", %{}, %{})
    end

    test "without the extension an optional task tool runs synchronously, a required one is refused" do
      assert %{"result" => %{"resultType" => "complete", "content" => [%{"text" => text}]}} =
               call(opts(), "slow_compute", %{"seconds" => 0, "label" => "x"}, %{})

      assert text == "Computed x in 0s."

      conn =
        ModernClient.post(opts(), "tools/call", %{"name" => "failing_job", "arguments" => %{}})

      assert conn.status == 400

      assert %{
               "error" => %{
                 "code" => -32_021,
                 "data" => %{"requiredCapabilities" => %{"extensions" => %{@ext => %{}}}}
               }
             } = ModernClient.json(conn)
    end

    test "tasks/* need the extension, a server with task tools, and a taskId" do
      for method <- ["tasks/get", "tasks/update", "tasks/cancel"] do
        params = %{"taskId" => "nope", "inputResponses" => %{}}

        assert %{"error" => %{"code" => -32_021}} = rpc(opts(), method, params, %{})

        assert %{
                 "error" => %{
                   "code" => -32_602,
                   "message" => "Failed to retrieve task: Task not found"
                 }
               } =
                 rpc(opts(), method, params, @tasks)

        assert %{"error" => %{"code" => -32_601}} =
                 rpc(ModernClient.opts(server: Plain), method, params, @tasks)
      end

      assert %{"error" => %{"code" => -32_602, "message" => "Missing taskId"}} =
               rpc(opts(), "tasks/get", %{}, @tasks)

      assert %{"error" => %{"code" => -32_602, "message" => "tasks/update needs inputResponses"}} =
               rpc(opts(), "tasks/update", %{"taskId" => "x"}, @tasks)

      for removed <- ["tasks/result", "tasks/list"] do
        assert %{"error" => %{"code" => -32_601}} =
                 rpc(opts(), removed, %{"taskId" => "x"}, @tasks)
      end
    end

    test "with tasks off, task tools run synchronously and the extension is not advertised" do
      on_exit(fn -> Supervisor.restart_child(SakeTest.Supervisor, Sake.Tasks) end)
      :ok = Supervisor.terminate_child(SakeTest.Supervisor, Sake.Tasks)

      assert %{"result" => %{"capabilities" => caps}} = rpc(opts(), "server/discover", %{}, %{})
      refute Map.has_key?(caps, "extensions")

      assert %{"result" => %{"resultType" => "complete", "isError" => true}} =
               call(opts(), "failing_job", %{})

      assert %{"error" => %{"code" => -32_601}} =
               rpc(opts(), "tasks/get", %{"taskId" => "x"}, @tasks)
    end

    test "a legacy session never gets a task" do
      session = LegacyClient.initialize(opts(), "2025-11-25", @tasks)

      conn =
        LegacyClient.post(opts(), session, "tools/call", %{
          "name" => "slow_compute",
          "arguments" => %{"seconds" => 0}
        })

      assert %{"result" => %{"content" => [%{"text" => "Computed result in 0s."}]} = result} =
               LegacyClient.json(conn)

      refute Map.has_key?(result, "taskId")

      conn =
        LegacyClient.post(opts(), session, "tools/call", %{
          "name" => "failing_job",
          "arguments" => %{}
        })

      assert %{"error" => %{"code" => -32_021}} = LegacyClient.json(conn)

      conn = LegacyClient.post(opts(), session, "tasks/get", %{"taskId" => "x"})
      assert %{"error" => %{"code" => -32_601}} = LegacyClient.json(conn)
    end
  end

  describe "lifecycle" do
    test "a task is created, readable at once, and completes with the synchronous result" do
      args = %{"seconds" => 0, "label" => "sum"}

      assert %{"result" => created} = call(opts(), "slow_compute", args)

      assert %{
               "resultType" => "task",
               "taskId" => id,
               "status" => "working",
               "createdAt" => created_at,
               "lastUpdatedAt" => _,
               "ttlMs" => 3_600_000,
               "pollIntervalMs" => 50
             } = created

      assert {:ok, <<_::144>>} = Base.url_decode64(id, padding: false)
      assert {:ok, _, 0} = DateTime.from_iso8601(created_at)

      for key <- ["result", "error", "inputRequests", "requestState"],
          do: refute(Map.has_key?(created, key))

      assert %{"result" => %{"taskId" => ^id, "resultType" => "complete"}} = get(opts(), id)

      task = await(opts(), id, &terminal?/1)
      sync = call(opts(), "slow_compute", args, %{})["result"]

      assert task["status"] == "completed"
      assert task["result"] == Map.drop(sync, ["resultType", "_meta"])
      refute Map.has_key?(task, "error")

      assert %{"result" => %{"_meta" => %{"io.modelcontextprotocol/serverInfo" => _}}} =
               get(opts(), id)
    end

    test "a tool error completes the task with isError; a raise fails it with a JSON-RPC error" do
      id = start(opts(), "failing_job", %{})
      task = await(opts(), id, &terminal?/1)

      assert %{"status" => "completed", "result" => %{"isError" => true, "content" => [_]}} = task

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          id = start(opts(), "protocol_error_job", %{})
          task = await(opts(), id, &terminal?/1)

          assert %{
                   "status" => "failed",
                   "statusMessage" => "The tool failed.",
                   "error" => %{"code" => -32_603, "message" => "The tool failed."}
                 } = task

          refute Map.has_key?(task, "result")
        end)

      assert log =~ "protocol_error_job always raises"
    end

    test "a missing capability inside a task fails it with -32021" do
      defmodule Needs do
        use Sake.Tool, name: "needs", task: true

        @impl true
        def execute(%{}, _ctx), do: {:error, {:missing_capability, %{"roots" => %{}}}}
      end

      defmodule NeedsServer do
        use Sake.Server, name: "needs", version: "1"
        tools [Needs]
      end

      opts = ModernClient.opts(server: NeedsServer)
      id = start(opts, "needs", %{})

      assert %{
               "status" => "failed",
               "error" => %{
                 "code" => -32_021,
                 "data" => %{"requiredCapabilities" => %{"roots" => %{}}}
               }
             } = await(opts, id, &terminal?/1)
    end

    test "argument errors and scope errors come before any task" do
      assert %{"result" => %{"resultType" => "complete", "isError" => true}} =
               call(opts(), "slow_compute", %{"seconds" => "soon"})
    end

    test "cancel: marked at once, the worker stopped, a terminal task acknowledged the same" do
      id = start(opts(), "slow_compute", %{"seconds" => 60})
      assert [_ | _] = Registry.lookup(Sake.Tasks.Registry, id)

      assert %{"result" => ack} = rpc(opts(), "tasks/cancel", %{"taskId" => id}, @tasks)
      assert ack == %{"resultType" => "complete", "_meta" => ack["_meta"]}

      assert %{"result" => %{"status" => "cancelled"} = task} = get(opts(), id)
      refute Map.has_key?(task, "result")
      Process.sleep(20)
      assert Registry.lookup(Sake.Tasks.Registry, id) == []

      assert %{"result" => %{"resultType" => "complete"}} =
               rpc(opts(), "tasks/cancel", %{"taskId" => id}, @tasks)

      done = start(opts(), "slow_compute", %{"seconds" => 0})
      await(opts(), done, &terminal?/1)
      rpc(opts(), "tasks/cancel", %{"taskId" => done}, @tasks)
      assert %{"result" => %{"status" => "completed"}} = get(opts(), done)
    end

    test "a cancellation seen from another node: the waiting tool stops, the task stays cancelled" do
      id = start(opts(), "confirm_delete", %{"filename" => "a.txt"}, @with_input)
      await(opts(), id, &(&1["status"] == "input_required"))

      # What tasks/cancel on another node does: the store only, no message.
      {:ok, _} =
        Sake.Tasks.update(SakeDev.ConformanceServer, id, &%{&1 | status: :cancelled})

      Process.sleep(150)
      assert Registry.lookup(Sake.Tasks.Registry, id) == []
      assert %{"result" => %{"status" => "cancelled"}} = get(opts(), id)
    end

    test "progress becomes the status message" do
      defmodule Steps do
        use Sake.Tool, name: "steps", task: true

        @impl true
        def execute(%{}, ctx) do
          Sake.Progress.report(ctx, 1, 2, "Halfway")
          Process.sleep(100)
          Sake.Progress.report(ctx, 2, 2)
          Process.sleep(100)
          {:ok, "done"}
        end
      end

      defmodule StepsServer do
        use Sake.Server, name: "steps", version: "1"
        tools [Steps]
      end

      opts = ModernClient.opts(server: StepsServer)
      id = start(opts, "steps", %{})
      assert await(opts, id, &(&1["statusMessage"] == "Halfway"))["status"] == "working"
      assert await(opts, id, &(&1["statusMessage"] == "2/2"))["status"] == "working"
      task = await(opts, id, &terminal?/1)
      refute Map.has_key?(task, "statusMessage")
    end

    test "telemetry: start and stop around the run, with the final status" do
      parent = self()

      :telemetry.attach_many(
        "tasks-test",
        [[:sake, :task, :start], [:sake, :task, :stop]],
        fn event, _measurements, meta, _ -> send(parent, {event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("tasks-test") end)

      id = start(opts(), "slow_compute", %{"seconds" => 0})

      assert_receive {[:sake, :task, :start], %{task_id: ^id, tool: "slow_compute"}}

      assert_receive {[:sake, :task, :stop],
                      %{task_id: ^id, status: :completed, server: SakeDev.ConformanceServer}}
    end
  end

  describe "input" do
    test "input_required with the request; unknown keys ignored; the answer resumes the task" do
      id = start(opts(), "confirm_delete", %{"filename" => "a.txt"}, @with_input)
      task = await(opts(), id, &(&1["status"] == "input_required"), @with_input)

      assert %{"confirm" => %{"method" => "elicitation/create", "params" => params}} =
               task["inputRequests"]

      assert params["message"] == "Delete a.txt?"

      assert %{"result" => ack} =
               rpc(
                 opts(),
                 "tasks/update",
                 %{"taskId" => id, "inputResponses" => %{"unknown" => %{"action" => "accept"}}},
                 @with_input
               )

      assert Map.keys(ack) -- ["_meta"] == ["resultType"]
      assert %{"result" => %{"status" => "input_required"}} = get(opts(), id, @with_input)

      answer = %{"action" => "accept", "content" => %{"confirm" => true}}

      rpc(
        opts(),
        "tasks/update",
        %{"taskId" => id, "inputResponses" => %{"confirm" => answer}},
        @with_input
      )

      task = await(opts(), id, &terminal?/1, @with_input)

      assert %{
               "status" => "completed",
               "result" => %{"content" => [%{"text" => "Deleted a.txt."}]}
             } = task

      # An answer after the fact changes nothing.
      rpc(
        opts(),
        "tasks/update",
        %{"taskId" => id, "inputResponses" => %{"confirm" => %{"action" => "decline"}}},
        @with_input
      )

      assert %{"result" => %{"status" => "completed"}} = get(opts(), id, @with_input)
    end

    test "several requests at once can be answered one at a time" do
      id = start(opts(), "multi_input", %{}, @with_input)

      task =
        await(opts(), id, &(map_size(&1["inputRequests"] || %{}) == 2), @with_input)

      assert Map.keys(task["inputRequests"]) == ["first", "second"]

      answer = fn name -> %{"action" => "accept", "content" => %{"name" => name}} end

      rpc(
        opts(),
        "tasks/update",
        %{"taskId" => id, "inputResponses" => %{"first" => answer.("A")}},
        @with_input
      )

      assert %{"result" => %{"status" => "input_required", "inputRequests" => pending}} =
               get(opts(), id, @with_input)

      assert Map.keys(pending) == ["second"]

      rpc(
        opts(),
        "tasks/update",
        %{"taskId" => id, "inputResponses" => %{"second" => answer.("B")}},
        @with_input
      )

      assert %{"result" => %{"content" => [%{"text" => "Answered: A, B"}]}} =
               await(opts(), id, &terminal?/1, @with_input)
    end

    test "sampling and roots inside a task, and a key asked twice is answered once" do
      defmodule Asker do
        use Sake.Tool, name: "asker", task: :optional

        @impl true
        def execute(%{}, ctx) do
          [sample, roots] =
            Sake.Input.all(ctx, [
              &Sake.Sampling.create_message(&1, :sample, [user: "hi"], max_tokens: 5),
              &Sake.Roots.list/1
            ])

          {:ok, %{text: text}} = sample
          {:ok, [%{uri: uri}]} = roots

          {:ok, %{text: again}} =
            Sake.Sampling.create_message(ctx, :sample, [user: "hi"], max_tokens: 5)

          {:ok, "#{text} #{uri} #{again}"}
        end
      end

      defmodule AskerServer do
        use Sake.Server, name: "asker", version: "1"
        tools [Asker]
      end

      client =
        connect(AskerServer, sampling: fn _params -> "yo" end, roots: [%{"uri" => "file:///r"}])

      # The tool runs as a task, and asks through it.
      assert {:ok, {:task, %{"taskId" => id}}} = call_tool_async(client, "asker")

      assert {:ok, %{"status" => "input_required", "inputRequests" => asked}} =
               await_task(client, id)

      assert asked != %{} and Map.keys(asked) -- ["sample", "roots"] == []
      :ok = cancel_task(client, id)

      # Followed to the end, the questions are answered through
      # tasks/update, and the sampling key asked twice reaches the client
      # once.
      assert {:ok, %{text: "yo file:///r yo"}} = call_tool(client, "asker")
      assert_asked "sampling/createMessage", %{"maxTokens" => 5}
      assert_asked "roots/list"
      refute_asked "sampling/createMessage"
    end

    test "prepare/2 asks on the original request, then the task takes over" do
      caps = @with_input

      assert %{"result" => %{"resultType" => "input_required", "requestState" => state} = r1} =
               call(opts(), "test_tool_with_task", %{}, caps)

      refute Map.has_key?(r1, "taskId")

      assert %{"result" => %{"resultType" => "task", "taskId" => id} = r2} =
               rpc(
                 opts(),
                 "tools/call",
                 %{
                   "name" => "test_tool_with_task",
                   "arguments" => %{},
                   "requestState" => state,
                   "inputResponses" => %{
                     "user_name" => %{"action" => "accept", "content" => %{"name" => "Alice"}}
                   }
                 },
                 caps
               )

      refute Map.has_key?(r2, "requestState")

      assert %{"result" => %{"content" => [%{"text" => "Hello, Alice!"}]}} =
               await(opts(), id, &terminal?/1, caps)
    end
  end

  describe "security" do
    test "a task belongs to its creator's principal; anyone else is told it does not exist" do
      ana = connect(SakeDev.ConformanceServer, scope: "ana")

      assert {:ok, {:task, %{"taskId" => id}}} =
               call_tool_async(ana, "slow_compute", %{"seconds" => 60})

      assert {:ok, %{"status" => "working"}} = get_task(ana, id)

      bob = connect(SakeDev.ConformanceServer, scope: "bob")
      nobody = connect(SakeDev.ConformanceServer)

      for refused <- [
            get_task(bob, id),
            update_task(bob, id, %{}),
            cancel_task(bob, id),
            get_task(nobody, id)
          ] do
        assert {:error,
                {:rpc,
                 %{"code" => -32_602, "message" => "Failed to retrieve task: Task not found"}}} =
                 refused
      end

      assert {:ok, %{"status" => "working"}} = get_task(ana, id)
      assert :ok = cancel_task(ana, id)
      assert {:ok, %{"status" => "cancelled"}} = get_task(ana, id)
    end

    test "the token's subject is the principal when there is one" do
      ctx = %Sake.Context{token: %{subject_id: "u1"}, scope: :ignored}
      assert Sake.Tasks.principal(ctx) == "subject:u1"
      assert Sake.Tasks.principal(%Sake.Context{}) == nil
      assert "scope:" <> digest = Sake.Tasks.principal(%Sake.Context{scope: %{id: 1}})
      assert byte_size(digest) == 64
      refute Sake.Tasks.principal(%Sake.Context{scope: %{id: 2}}) == "scope:" <> digest
    end

    test "Mcp-Name must carry the task ID" do
      id = start(opts(), "slow_compute", %{"seconds" => 0})

      conn =
        ModernClient.post(opts(), "tasks/get", %{"taskId" => id},
          capabilities: @tasks,
          headers: [{"mcp-name", "someone-else"}]
        )

      assert conn.status == 400
      assert %{"error" => %{"code" => -32_020, "message" => message}} = ModernClient.json(conn)
      assert message =~ "Mcp-Name"

      conn =
        ModernClient.post(opts(), "tasks/cancel", %{"taskId" => id},
          capabilities: @tasks,
          mirror: false,
          headers: [{"mcp-method", "tasks/cancel"}]
        )

      assert %{"error" => %{"code" => -32_020, "message" => "Mcp-Name header is missing"}} =
               ModernClient.json(conn)
    end

    test "an expired task is gone, and pruning deletes it" do
      %{store: {module, state}} = Sake.Tasks.config()
      past = DateTime.add(Sake.Tasks.now(), -10, :second)

      record = %Record{
        id: "expired-task",
        tool: "slow_compute",
        ttl_ms: 1_000,
        poll_interval_ms: 50,
        created_at: past,
        updated_at: past,
        expires_at: DateTime.add(past, 1, :second)
      }

      :ok = module.insert(state, record)
      assert {:ok, _} = module.get(state, "expired-task")
      assert Sake.Tasks.fetch("expired-task") == :error

      assert %{"error" => %{"code" => -32_602}} =
               rpc(opts(), "tasks/get", %{"taskId" => "expired-task"}, @tasks)

      assert Sake.Tasks.update(SakeDev.ConformanceServer, "expired-task", & &1) == :error
      :ok = module.prune(state, Sake.Tasks.now())
      assert module.get(state, "expired-task") == :error
    end
  end

  describe "notifications" do
    setup do
      %{url: HTTP.start() <> "/mcp"}
    end

    defp listen_body(id, notifications, caps) do
      Sake.JSONRPC.request(id, "subscriptions/listen", %{
        "notifications" => notifications,
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => caps
        }
      })
    end

    @listen_headers [
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", "subscriptions/listen"}
    ]

    test "taskIds without the extension is -32021", %{url: url} do
      resp =
        Req.post!(url,
          json: listen_body("l1", %{"taskIds" => ["x"]}, %{}),
          headers: @listen_headers
        )

      assert resp.status == 400
      assert %{"error" => %{"code" => -32_021}} = resp.body
    end

    test "the caller's own tasks are acknowledged and followed to the end", %{url: url} do
      opts = ModernClient.opts()
      id = start(opts, "export", %{"n" => 2, "delay_ms" => 0}, @with_input)
      await(opts, id, &(&1["status"] == "input_required"), @with_input)

      body = listen_body("l2", %{"taskIds" => [id, "not-a-task"]}, @tasks)

      spawn(fn ->
        Process.sleep(200)

        rpc(
          opts,
          "tasks/update",
          %{
            "taskId" => id,
            "inputResponses" => %{
              "format" => %{"action" => "accept", "content" => %{"format" => "csv"}}
            }
          },
          @with_input
        )
      end)

      assert {:ok, [ack | notifications]} =
               HTTP.sse(url, body, @listen_headers, fn events ->
                 Enum.any?(events, &(&1["params"]["status"] == "completed"))
               end)

      assert ack["params"]["notifications"] == %{"taskIds" => [id]}

      assert [
               %{"method" => "notifications/tasks", "params" => working},
               %{"method" => "notifications/tasks", "params" => completed}
             ] = notifications

      assert %{"taskId" => ^id, "status" => "working"} = working
      assert working["_meta"]["io.modelcontextprotocol/subscriptionId"] == "l2"

      assert %{"status" => "completed", "result" => %{"content" => [%{"text" => text}]}} =
               completed

      assert text == "Exported 2 issues as csv."
    end
  end
end
