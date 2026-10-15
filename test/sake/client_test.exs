defmodule Sake.ClientTest do
  use ExUnit.Case, async: false

  alias Sake.Client
  alias SakeTest.HTTP

  setup do
    %{url: HTTP.start() <> "/mcp"}
  end

  for era <- [:modern, :legacy] do
    describe "#{era}" do
      @era era

      test "connect, discover, tools, call, resources, prompts, completion, ping, close", %{
        url: url
      } do
        assert {:ok, session} = Client.connect(url, era: @era)
        assert session.era == @era
        assert session.server_info["name"] == "sake-dev"
        assert {:ok, tools, session} = Client.list_tools(session)

        assert Enum.map(tools, & &1.name) == [
                 "echo",
                 "add",
                 "slow",
                 "confirm",
                 "connect",
                 "summarize",
                 "roots",
                 "export",
                 "issue_board"
               ]

        assert %Sake.Tool.Spec{headers: %{"Precision" => ["precision"]}} =
                 Enum.find(tools, &(&1.name == "add"))

        assert {:ok, result, session} =
                 Client.call_tool(session, "add", %{"a" => 1, "b" => 2, "precision" => 1})

        assert result.structured == %{"sum" => 3.0} and result.is_error == false and
                 result.text =~ "3.0"

        assert [%Sake.Content{type: :text}] = result.content

        assert {:ok, result, session} =
                 Client.call_tool(session, "slow", %{"n" => 2, "delay_ms" => 0})

        assert result.text == "counted to 2"

        assert {:ok, %{is_error: true, text: text}, session} =
                 Client.call_tool(session, "add", %{"a" => "x"})

        assert text =~ "Invalid arguments"

        assert {:error, {:rpc, %{"code" => -32_602}}, session} =
                 Client.call_tool(session, "nope", %{})

        assert {:ok, resources, session} = Client.list_resources(session)
        assert Enum.map(resources, & &1["uri"]) == ["dev://readme", "issue://1", "issue://2"]

        assert {:ok, [%Sake.Content{type: :resource, uri: "issue://1", text: text}], session} =
                 Client.read_resource(session, "issue://1")

        assert JSON.decode!(text)["id"] == "1"

        assert {:ok, [%{"uriTemplate" => "issue://{id}"}], session} =
                 Client.list_resource_templates(session)

        assert {:ok, [%{"name" => "triage"}], session} = Client.list_prompts(session)

        assert {:ok, %{"messages" => [%{"role" => "user"}]}, session} =
                 Client.get_prompt(session, "triage", %{"id" => "1"})

        assert {:ok, %{"values" => ["direct"]}, session} =
                 Client.complete(session, {:prompt, "triage"}, "tone", "d")

        assert {:ok, session} = Client.ping(session)
        assert :ok = Client.close(session)
      end

      test "elicitation through on_input", %{url: url} do
        parent = self()

        on_input = fn requests, _session ->
          send(parent, {:asked, requests})

          Map.new(requests, fn {key, _req} ->
            {key, %{"action" => "accept", "content" => %{"name" => "Rui"}}}
          end)
        end

        assert {:ok, session} = Client.connect(url, era: @era, on_input: on_input)
        assert {:ok, %{text: "Hello, Rui!"}, _} = Client.call_tool(session, "confirm", %{})
        assert_receive {:asked, %{"who" => %{"method" => "elicitation/create"}}}
      end

      test "without on_input the tool sees a cancel", %{url: url} do
        assert {:ok, session} =
                 Client.connect(url, era: @era, capabilities: %{"elicitation" => %{}})

        assert {:ok, %{is_error: true, text: "Cancelled."}, _} =
                 Client.call_tool(session, "confirm", %{})
      end

      test "sampling through sampling:", %{url: url} do
        parent = self()

        sampling = fn params, _session ->
          send(parent, {:sampled, params})

          {:ok,
           %{
             "role" => "assistant",
             "content" => %{"type" => "text", "text" => "Short."},
             "model" => "test-model"
           }}
        end

        assert {:ok, session} = Client.connect(url, era: @era, sampling: sampling)
        assert session.capabilities == %{"sampling" => %{}}

        assert {:ok, %{text: "Short.", is_error: false}, _} =
                 Client.call_tool(session, "summarize", %{"text" => "Long."})

        assert_receive {:sampled, %{"maxTokens" => 100, "messages" => [%{"role" => "user"}]}}
      end

      test "a task tool: followed to its result on modern, run synchronously on legacy", %{
        url: url
      } do
        on_input = fn requests, _session ->
          Map.new(requests, fn {key, _} ->
            {key, %{"action" => "accept", "content" => %{"format" => "csv"}}}
          end)
        end

        assert {:ok, session} = Client.connect(url, era: @era, on_input: on_input)

        assert {:ok, %{text: "Exported 2 issues as csv."}, _} =
                 Client.call_tool(session, "export", %{"n" => 2, "delay_ms" => 0})
      end

      test "roots through roots:, as a list or a function", %{url: url} do
        roots = [%{"uri" => "file:///work", "name" => "Work"}]
        assert {:ok, session} = Client.connect(url, era: @era, roots: roots)
        assert session.capabilities == %{"roots" => %{"listChanged" => false}}

        assert {:ok, %{text: "file:///work (Work)"}, _} = Client.call_tool(session, "roots", %{})

        assert {:ok, session} =
                 Client.connect(url,
                   era: @era,
                   roots: fn _session -> [%{"uri" => "file:///f"}] end
                 )

        assert {:ok, %{text: "file:///f (unnamed)"}, _} = Client.call_tool(session, "roots", %{})
      end

      test "MCP Apps: ui: true declares the extension; tools and UI contents carry _meta.ui", %{
        url: url
      } do
        assert {:ok, session} = Client.connect(url, era: @era, ui: true)

        assert session.capabilities == %{
                 "extensions" => %{
                   "io.modelcontextprotocol/ui" => %{"mimeTypes" => ["text/html;profile=mcp-app"]}
                 }
               }

        assert {:ok, tools, session} = Client.list_tools(session)
        by_name = Map.new(tools, &{&1.name, &1})

        assert %Sake.Tool.Spec{ui: "ui://sake-dev/issue-board", visibility: [:model, :app]} =
                 by_name["issue_board"]

        assert %Sake.Tool.Spec{ui: "ui://sake-dev/issue-board", visibility: [:app]} =
                 by_name["issue_details"]

        assert %Sake.Tool.Spec{ui: nil, visibility: [:model, :app]} = by_name["echo"]

        assert {:ok, resources, session} = Client.list_resources(session)
        assert %{"_meta" => %{"ui" => %{"prefersBorder" => true}}} = List.last(resources)

        assert {:ok, [%Sake.Content{} = doc], session} =
                 Client.read_resource(session, "ui://sake-dev/issue-board")

        assert doc.mime_type == "text/html;profile=mcp-app"
        assert doc.meta == %{"ui" => %{"prefersBorder" => true}}
        assert doc.text =~ "<!doctype html>" and doc.text =~ "ui/initialize"

        assert {:ok, %{structured: %{"issues" => [_, _, _]}}, session} =
                 Client.call_tool(session, "issue_board", %{})

        assert {:ok, %{structured: %{"id" => "2", "state" => "open"}}, _} =
                 Client.call_tool(session, "issue_details", %{"id" => "2"})
      end

      test "MCP Apps: without ui: the tools come without their UI", %{url: url} do
        assert {:ok, session} = Client.connect(url, era: @era)
        assert {:ok, tools, session} = Client.list_tools(session)
        refute Enum.any?(tools, &(&1.name == "issue_details"))
        assert %Sake.Tool.Spec{ui: nil} = Enum.find(tools, &(&1.name == "issue_board"))

        assert {:error, {:rpc, %{"code" => -32_602}}, _} =
                 Client.call_tool(session, "issue_details", %{"id" => "2"})
      end

      test "on_notification sees a call's progress", %{url: url} do
        parent = self()
        on_notification = fn method, params -> send(parent, {:notified, method, params}) end

        assert {:ok, session} = Client.connect(url, era: @era, on_notification: on_notification)

        assert {:ok, %{text: "counted to 2"}, _} =
                 Client.call_tool(session, "slow", %{"n" => 2, "delay_ms" => 0})

        assert_received {:notified, "notifications/progress", %{"progress" => 1, "total" => 2}}
        assert_received {:notified, "notifications/progress", %{"progress" => 2}}
      end
    end
  end

  describe "tasks (modern)" do
    defmodule ConformanceRouter do
      use Plug.Router
      plug :match
      plug :dispatch

      forward "/mcp",
        to: Sake.Plug,
        init_opts: [server: SakeDev.ConformanceServer, secret: String.duplicate("s", 64)]
    end

    setup do
      %{url: HTTP.start(ConformanceRouter) <> "/mcp"}
    end

    test "the extension is declared per request, and only on modern", %{url: url} do
      assert {:ok, session} = Client.connect(url, era: :modern)
      assert session.capabilities == %{}

      assert {:ok, {:task, %{"taskId" => id, "status" => "working"}}, session} =
               Client.call_tool_async(session, "slow_compute", %{"seconds" => 0})

      assert {:ok, %{"taskId" => ^id}, _} = Client.get_task(session, id)

      assert {:ok, session} = Client.connect(url, era: :modern, tasks: false)

      assert {:ok, %Sake.Client.ToolResult{text: "Computed result in 0s."}, session} =
               Client.call_tool_async(session, "slow_compute", %{"seconds" => 0})

      assert {:error, {:http, 400, %{"error" => %{"code" => -32_021}}}, _} =
               Client.call_tool(session, "failing_job", %{})
    end

    test "call_tool follows a task: completed, a tool error, failed, cancelled", %{url: url} do
      assert {:ok, session} = Client.connect(url, era: :modern)

      assert {:ok, %{text: "Computed x in 0s.", is_error: false}, session} =
               Client.call_tool(session, "slow_compute", %{"seconds" => 0, "label" => "x"})

      assert {:ok, %{is_error: true, text: "The job failed."}, session} =
               Client.call_tool(session, "failing_job", %{})

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:rpc, %{"code" => -32_603}}, _} =
                 Client.call_tool(session, "protocol_error_job", %{})
      end)

      assert {:ok, {:task, %{"taskId" => id}}, session} =
               Client.call_tool_async(session, "slow_compute", %{"seconds" => 60})

      assert {:ok, session} = Client.cancel_task(session, id)
      assert {:ok, %{"status" => "cancelled"}, _} = Client.get_task(session, id)
    end

    test "input requests are answered through tasks/update, once each", %{url: url} do
      parent = self()

      on_input = fn requests, _session ->
        send(parent, {:asked, Map.keys(requests)})

        Map.new(requests, fn {key, _} ->
          {key, %{"action" => "accept", "content" => %{"name" => key, "confirm" => true}}}
        end)
      end

      assert {:ok, session} = Client.connect(url, era: :modern, on_input: on_input)

      assert {:ok, %{text: "Deleted a.txt."}, session} =
               Client.call_tool(session, "confirm_delete", %{"filename" => "a.txt"})

      assert_received {:asked, ["confirm"]}
      refute_received {:asked, _}

      assert {:ok, %{text: "Answered: first, second"}, _} =
               Client.call_tool(session, "multi_input", %{})

      # Both questions arrive pending at once or one after the other,
      # depending on timing; either way each is asked exactly once.
      asked = collect_asked([])
      assert Enum.sort(asked) == ["first", "second"]
    end

    test "the lower-level calls", %{url: url} do
      assert {:ok, session} =
               Client.connect(url, era: :modern, capabilities: %{"elicitation" => %{}})

      assert {:ok, {:task, %{"taskId" => id}}, session} =
               Client.call_tool_async(session, "confirm_delete", %{"filename" => "b.txt"})

      task = wait_status(session, id, "input_required")
      assert %{"confirm" => %{"method" => "elicitation/create"}} = task["inputRequests"]

      assert {:ok, session} =
               Client.update_task(session, id, %{
                 "confirm" => %{"action" => "accept", "content" => %{"confirm" => false}}
               })

      task = wait_status(session, id, "completed")
      assert %{"result" => %{"content" => [%{"text" => "Kept b.txt."}]}} = task

      assert {:error, {:rpc, %{"code" => -32_602}}, _} = Client.get_task(session, "nope")
    end

    test "a task still running after task_timeout is cancelled", %{url: url} do
      parent = self()
      handler = fn _event, _measurements, meta, _ -> send(parent, {:started, meta.task_id}) end
      :telemetry.attach("client-timeout", [:sake, :task, :start], handler, nil)
      on_exit(fn -> :telemetry.detach("client-timeout") end)

      assert {:ok, session} = Client.connect(url, era: :modern, task_timeout: 100)

      assert {:error, :task_timeout, _} =
               Client.call_tool(session, "slow_compute", %{"seconds" => 60})

      assert_received {:started, id}
      assert {:ok, %{status: :cancelled}} = Sake.Tasks.fetch(id)
    end
  end

  defp collect_asked(acc) do
    receive do
      {:asked, keys} -> collect_asked(acc ++ keys)
    after
      0 -> acc
    end
  end

  defp wait_status(session, id, status, tries \\ 100) do
    {:ok, task, session} = Client.get_task(session, id)

    cond do
      task["status"] == status -> task
      tries == 0 -> flunk("task #{id} never became #{status}: #{inspect(task)}")
      true -> Process.sleep(20) && wait_status(session, id, status, tries - 1)
    end
  end

  test "on a legacy stream, a sampling error goes back as a JSON-RPC error", %{url: url} do
    sampling = fn _params, _session -> {:error, %{"code" => -1, "message" => "Declined"}} end
    assert {:ok, session} = Client.connect(url, era: :legacy, sampling: sampling)

    assert {:ok, %{is_error: true, text: "The client did not summarize."}, _} =
             Client.call_tool(session, "summarize", %{"text" => "x"})
  end

  test "a legacy server request nothing can answer gets an error; elicitation a cancel" do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}/mcp"
    parent = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      msg = JSON.decode!(body)

      case msg do
        %{"method" => "initialize"} ->
          json(conn, msg["id"], %{"protocolVersion" => "2025-11-25", "capabilities" => %{}})

        %{"method" => "notifications/initialized"} ->
          Plug.Conn.resp(conn, 202, "")

        %{"method" => "tools/call"} ->
          requests = [
            Sake.JSONRPC.request("s1", "sampling/createMessage", %{"messages" => []}),
            Sake.JSONRPC.request("r1", "roots/list", %{}),
            Sake.JSONRPC.request("e1", "elicitation/create", %{"message" => "?"}),
            Sake.JSONRPC.request("p1", "ping", %{}),
            Sake.JSONRPC.result(msg["id"], %{"content" => []})
          ]

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, Enum.map_join(requests, &"data: #{JSON.encode!(&1)}\n\n"))

        answer ->
          send(parent, {:answer, answer})
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    assert {:ok, session} = Client.connect(url, era: :legacy)
    assert {:ok, %{content: []}, _} = Client.call_tool(session, "x", %{})

    assert_receive {:answer, %{"id" => "s1", "error" => %{"code" => -32_601}}}
    assert_receive {:answer, %{"id" => "r1", "error" => %{"code" => -32_601}}}
    assert_receive {:answer, %{"id" => "e1", "result" => %{"action" => "cancel"}}}
    assert_receive {:answer, %{"id" => "p1", "error" => %{"code" => -32_601}}}
  end

  defp json(conn, id, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end

  test "a bad tool definition from a server is dropped with a warning" do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}/mcp"

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      msg = JSON.decode!(body)

      result =
        case msg["method"] do
          "server/discover" ->
            %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{"tools" => %{}}}

          "tools/list" ->
            %{
              "tools" => [
                %{"name" => "ok", "inputSchema" => %{"type" => "object"}},
                %{
                  "name" => "bad",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{"n" => %{"type" => "number", "x-mcp-header" => "N"}}
                  }
                },
                %{
                  "name" => "twice",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{
                      "a" => %{"type" => "string", "x-mcp-header" => "Region"},
                      "b" => %{"type" => "string", "x-mcp-header" => "Region"}
                    }
                  }
                }
              ]
            }
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => msg["id"], "result" => result})
      )
    end)

    {:ok, session} = Client.connect(url)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, [%{name: "ok"}], _} = Client.list_tools(session)
      end)

    assert log =~ "bad" and log =~ "x-mcp-header"
    assert log =~ ~s("twice": invalid x-mcp-header \(duplicate names\))
  end

  test "a tool's UI from the deprecated flat key, and unknown audiences dropped" do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}/mcp"

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      msg = JSON.decode!(body)

      result =
        case msg["method"] do
          "server/discover" ->
            %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{"tools" => %{}}}

          "tools/list" ->
            %{
              "tools" => [
                %{"name" => "flat", "_meta" => %{"ui/resourceUri" => "ui://x/flat"}},
                %{
                  "name" => "odd",
                  "_meta" => %{
                    "ui" => %{"resourceUri" => "ui://x/odd", "visibility" => ["app", "robot"]}
                  }
                }
              ]
            }
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => msg["id"], "result" => result})
      )
    end)

    {:ok, session} = Client.connect(url, ui: true)

    assert {:ok, [flat, odd], _} = Client.list_tools(session)
    assert %{ui: "ui://x/flat", visibility: [:model, :app]} = flat
    assert %{ui: "ui://x/odd", visibility: [:app]} = odd
  end

  test "a false argument is mirrored into its header like any other value" do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}/mcp"
    test = self()

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      msg = JSON.decode!(body)

      result =
        case msg["method"] do
          "server/discover" ->
            %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{"tools" => %{}}}

          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => "flags",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{
                      "verbose" => %{"type" => "boolean", "x-mcp-header" => "Verbose"},
                      "debug" => %{"type" => "boolean", "x-mcp-header" => "Debug"}
                    }
                  }
                }
              ]
            }

          "tools/call" ->
            send(test, {:headers, conn.req_headers})
            %{"content" => []}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => msg["id"], "result" => result})
      )
    end)

    {:ok, session} = Client.connect(url)
    {:ok, _tools, session} = Client.list_tools(session)
    {:ok, _result, _session} = Client.call_tool(session, "flags", %{"verbose" => false})

    assert_received {:headers, headers}
    assert {"mcp-param-verbose", "false"} in headers
    refute List.keymember?(headers, "mcp-param-debug", 0)
  end

  test "pagination stops when a server keeps returning the same cursor" do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}/mcp"

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      msg = JSON.decode!(body)

      result =
        case msg["method"] do
          "server/discover" ->
            %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{"tools" => %{}}}

          "tools/list" ->
            %{"tools" => [], "nextCursor" => "same-cursor"}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => msg["id"], "result" => result})
      )
    end)

    {:ok, session} = Client.connect(url)
    assert {:error, :pagination_loop, _session} = Client.list_tools(session)
  end
end
