defmodule Sake.TraceTest do
  # The server's spans, as the OpenTelemetry SDK records them: each test
  # captures the spans of the traces it starts (SakeTest.Spans).
  use ExUnit.Case, async: false

  alias SakeTest.{LegacyClient, ModernClient, Pipe, Spans}

  @tasks %{"extensions" => %{"io.modelcontextprotocol/tasks" => %{}}}

  setup do
    Spans.capture()
    on_exit(fn -> Application.delete_env(:sake, :opentelemetry) end)
    %{opts: ModernClient.opts(server: SakeTest.TracedServer)}
  end

  # A client's span, ended, and the `_meta` that carries it.
  defp client_span(baggage \\ nil) do
    {_, span_ctx} = Spans.root("client", fn -> :ok end)
    meta = %{"traceparent" => Spans.traceparent(span_ctx)}
    meta = if baggage, do: Map.put(meta, "baggage", baggage), else: meta
    {span_ctx, meta}
  end

  defp call(opts, name, arguments, meta, request_opts \\ []) do
    ModernClient.post(
      opts,
      "tools/call",
      %{"name" => name, "arguments" => arguments},
      Keyword.merge([meta: meta], request_opts)
    )
  end

  defp child_of?(span, %{span_id: parent_id, trace_id: trace_id}),
    do: span.trace_id == trace_id and span.parent_span_id == parent_id

  defp child_of?(span, span_ctx),
    do: child_of?(span, %{span_id: Spans.span_id(span_ctx), trace_id: Spans.trace_id(span_ctx)})

  describe "the server span" do
    test "is the child of the client's span in _meta, and the tool's spans nest under it",
         %{opts: opts} do
      {client, meta} = client_span("user=ana,tier=gold")

      conn = call(opts, "traced", %{"note" => "secret"}, meta)
      assert conn.status == 200

      # The context in _meta brought its baggage to the tool.
      assert %{"result" => %{"structuredContent" => %{"baggage" => baggage}}} =
               ModernClient.json(conn)

      assert baggage == %{"user" => "ana", "tier" => "gold"}

      %{"tools/call traced" => server, "inside the tool" => inside} =
        Spans.await(["tools/call traced", "inside the tool"])

      assert server.kind == :server
      assert child_of?(server, client)
      assert child_of?(inside, server)
      assert server.links == []
      assert server.status == :unset

      assert server.attributes == %{
               "mcp.method.name" => "tools/call",
               "mcp.protocol.version" => "2026-07-28",
               "gen_ai.tool.name" => "traced",
               "gen_ai.operation.name" => "execute_tool",
               "jsonrpc.request.id" => "1",
               "network.transport" => "tcp",
               "network.protocol.name" => "http",
               "network.protocol.version" => "1.1",
               "client.address" => "127.0.0.1"
             }
    end

    test "links the HTTP request's own trace context", %{opts: opts} do
      {client, meta} = client_span()
      http = Spans.remote()

      call(opts, "traced", %{}, meta, headers: [{"traceparent", Spans.traceparent(http)}])

      %{"tools/call traced" => server} = Spans.await(["tools/call traced"])
      assert child_of?(server, client)
      assert server.links == [%{trace_id: Spans.trace_id(http), span_id: Spans.span_id(http)}]
    end

    test "links the span current when the request arrives (an instrumented HTTP server)",
         %{opts: opts} do
      {client, meta} = client_span()
      {_, http} = Spans.root("POST /mcp", fn -> call(opts, "traced", %{}, meta) end)

      %{"tools/call traced" => server} = Spans.await(["tools/call traced"])
      assert child_of?(server, client)
      assert server.links == [%{trace_id: Spans.trace_id(http), span_id: Spans.span_id(http)}]
    end

    test "without a context in _meta, is the child of the transport's", %{opts: opts} do
      http = Spans.remote()
      call(opts, "traced", %{}, %{}, headers: [{"traceparent", Spans.traceparent(http)}])

      %{"tools/call traced" => server, "inside the tool" => inside} =
        Spans.await(["tools/call traced", "inside the tool"])

      assert child_of?(server, http)
      assert server.links == []
      assert child_of?(inside, server)
    end

    test "names its target: a prompt, or a resource only as an attribute", %{opts: opts} do
      {_client, meta} = client_span()

      ModernClient.post(opts, "prompts/get", %{"name" => "triage", "arguments" => %{"id" => "7"}},
        meta: meta
      )

      ModernClient.post(opts, "resources/read", %{"uri" => "dev://readme"}, meta: meta, id: 2)
      ModernClient.post(opts, "tools/list", %{}, meta: meta, id: 3)

      %{"prompts/get triage" => prompt, "resources/read" => read, "tools/list" => list} =
        Spans.await(["prompts/get triage", "resources/read", "tools/list"])

      assert prompt.attributes["gen_ai.prompt.name"] == "triage"
      refute Map.has_key?(prompt.attributes, "gen_ai.operation.name")
      refute Map.has_key?(prompt.attributes, "gen_ai.prompt.variable.id")
      assert read.attributes["mcp.resource.uri"] == "dev://readme"
      assert read.attributes["jsonrpc.request.id"] == "2"
      assert list.attributes["mcp.method.name"] == "tools/list"
    end

    test "runs the handler of a streamed response in its own process, under the span",
         %{opts: opts} do
      {client, meta} = client_span()
      conn = call(opts, "traced", %{}, Map.put(meta, "progressToken", "p"))
      assert ["text/event-stream" <> _] = Plug.Conn.get_resp_header(conn, "content-type")

      %{"tools/call traced" => server, "inside the tool" => inside} =
        Spans.await(["tools/call traced", "inside the tool"])

      assert child_of?(server, client)
      assert child_of?(inside, server)
    end
  end

  describe "errors" do
    test "a tool error is error.type tool_error", %{opts: opts} do
      {_client, meta} = client_span()
      call(opts, "failing", %{}, meta)

      %{"tools/call failing" => span} = Spans.await(["tools/call failing"])
      assert span.attributes["error.type"] == "tool_error"
      assert {:error, _} = span.status
    end

    test "a JSON-RPC error from the server is an error, with its code and message", %{opts: opts} do
      {_client, meta} = client_span()
      call(opts, "only_task", %{}, meta)

      %{"tools/call only_task" => span} = Spans.await(["tools/call only_task"])
      assert span.attributes["rpc.response.status_code"] == "-32021"
      assert span.attributes["error.type"] == "-32021"
      assert span.status == {:error, "Missing required client capability"}
    end

    test "the caller's mistakes are not the server's errors", %{opts: opts} do
      {_client, meta} = client_span()
      call(opts, "nope", %{}, meta)
      ModernClient.post(opts, "nope/nope", %{}, meta: meta, id: 2)

      %{"tools/call nope" => unknown, "nope/nope" => missing} =
        Spans.await(["tools/call nope", "nope/nope"])

      assert unknown.attributes["rpc.response.status_code"] == "-32602"
      assert missing.attributes["rpc.response.status_code"] == "-32601"

      for span <- [unknown, missing] do
        refute Map.has_key?(span.attributes, "error.type")
        assert span.status == :unset
      end
    end

    test "a handler that fails is an internal error", %{opts: opts} do
      {_client, meta} = client_span()
      opts = %{opts | reraise: true}

      ExUnit.CaptureLog.capture_log(fn -> call(opts, "boom", %{}, meta) end)

      %{"tools/call boom" => span} = Spans.await(["tools/call boom"])
      assert span.attributes["error.type"] == "-32603"
      assert {:error, "The request failed: kaboom"} = span.status
    end
  end

  describe "tasks" do
    test "the run is an execute_tool span, the child of the tools/call that started it",
         %{opts: opts} do
      {client, meta} = client_span()
      conn = call(opts, "traced_task", %{}, meta, capabilities: @tasks)

      assert %{"result" => %{"resultType" => "task", "taskId" => task_id}} =
               ModernClient.json(conn)

      %{
        "tools/call traced_task" => server,
        "execute_tool traced_task" => run,
        "inside the task" => inside
      } = Spans.await(["tools/call traced_task", "execute_tool traced_task", "inside the task"])

      assert child_of?(server, client)
      assert child_of?(run, server)
      assert child_of?(inside, run)
      assert run.kind == :internal

      assert run.attributes == %{
               "gen_ai.operation.name" => "execute_tool",
               "gen_ai.tool.name" => "traced_task",
               "gen_ai.tool.call.id" => task_id
             }
    end
  end

  describe "the legacy era" do
    test "the same, with the session's identity", %{opts: opts} do
      session = LegacyClient.initialize(opts, "2025-11-25")
      {:ok, %{nonce: nonce}} = Sake.Server.Session.verify(ModernClient.secret(), session.id)
      {client, meta} = client_span()

      conn =
        LegacyClient.post(opts, session, "tools/call", %{
          "name" => "traced",
          "arguments" => %{},
          "_meta" => meta
        })

      assert conn.status == 200

      %{"tools/call traced" => server, "inside the tool" => inside} =
        Spans.await(["tools/call traced", "inside the tool"])

      assert child_of?(server, client)
      assert child_of?(inside, server)
      assert server.attributes["mcp.protocol.version"] == "2025-11-25"
      assert server.attributes["mcp.session.id"] == nonce
    end

    test "initialize names the revision it agreed on", %{opts: opts} do
      {client, meta} = client_span()

      LegacyClient.raw(
        opts,
        nil,
        Sake.JSONRPC.request(0, "initialize", %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "t", "version" => "0"},
          "_meta" => meta
        }),
        header: "2025-06-18"
      )

      %{"initialize" => span} = Spans.await(["initialize"])
      assert child_of?(span, client)
      assert span.attributes["mcp.protocol.version"] == "2025-06-18"
      assert span.attributes["jsonrpc.request.id"] == "0"
    end
  end

  describe "stdio" do
    setup do
      pipe = Pipe.start()
      test = self()

      {:ok, _} =
        Task.start_link(fn ->
          Sake.Stdio.run(SakeTest.TracedServer, input: pipe, output: pipe)
          send(test, :stopped)
        end)

      on_exit(fn -> Pipe.close(pipe) end)
      %{pipe: pipe}
    end

    test "a modern request: the span is the child of _meta's, over a pipe", %{pipe: pipe} do
      {client, meta} = client_span()

      meta =
        Map.merge(meta, %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })

      Pipe.push(
        pipe,
        Sake.JSONRPC.request(1, "tools/call", %{
          "name" => "traced",
          "arguments" => %{},
          "_meta" => meta
        })
      )

      assert_receive {:pipe, ^pipe, %{"id" => 1, "result" => _}}, 2_000

      %{"tools/call traced" => server, "inside the tool" => inside} =
        Spans.await(["tools/call traced", "inside the tool"])

      assert child_of?(server, client)
      assert child_of?(inside, server)
      assert server.attributes["network.transport"] == "pipe"
      refute Map.has_key?(server.attributes, "mcp.session.id")
      refute Map.has_key?(server.attributes, "client.address")
    end

    test "the legacy session: initialize and the requests in it", %{pipe: pipe} do
      {client, meta} = client_span()

      Pipe.push(
        pipe,
        Sake.JSONRPC.request(0, "initialize", %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "t", "version" => "0"},
          "_meta" => meta
        })
      )

      assert_receive {:pipe, ^pipe, %{"id" => 0, "result" => _}}, 2_000

      Pipe.push(
        pipe,
        Sake.JSONRPC.request(1, "tools/call", %{
          "name" => "failing",
          "arguments" => %{},
          "_meta" => meta
        })
      )

      Pipe.push(pipe, Sake.JSONRPC.request(2, "logging/setLevel", %{"level" => "info"}))
      assert_receive {:pipe, ^pipe, %{"id" => 1, "result" => _}}, 2_000
      assert_receive {:pipe, ^pipe, %{"id" => 2, "result" => _}}, 2_000

      %{"initialize" => init, "tools/call failing" => failing} =
        Spans.await(["initialize", "tools/call failing"])

      assert child_of?(init, client)
      assert child_of?(failing, client)
      assert init.attributes["mcp.protocol.version"] == "2025-11-25"
      assert failing.attributes["error.type"] == "tool_error"
      assert failing.attributes["mcp.session.id"] == init.attributes["mcp.session.id"]
      assert is_binary(failing.attributes["mcp.session.id"])
    end
  end

  describe "configuration" do
    test "record_content: true records the arguments and results", %{opts: opts} do
      Application.put_env(:sake, :opentelemetry, record_content: true)
      {_client, meta} = client_span("user=ana")

      call(opts, "traced", %{"note" => "secret"}, meta)

      ModernClient.post(
        opts,
        "prompts/get",
        %{"name" => "triage", "arguments" => %{"id" => "7", "tone" => "direct"}},
        meta: meta,
        id: 2
      )

      %{"tools/call traced" => tool, "prompts/get triage" => prompt} =
        Spans.await(["tools/call traced", "prompts/get triage"])

      assert JSON.decode!(tool.attributes["gen_ai.tool.call.arguments"]) == %{"note" => "secret"}

      assert JSON.decode!(tool.attributes["gen_ai.tool.call.result"]) == %{
               "baggage" => %{"user" => "ana"}
             }

      assert prompt.attributes["gen_ai.prompt.variable.id"] == "7"
      assert prompt.attributes["gen_ai.prompt.variable.tone"] == "direct"
    end

    test "enabled: false makes no spans and changes nothing else", %{opts: opts} do
      {_client, meta} = client_span()
      Spans.await(["client"])
      Application.put_env(:sake, :opentelemetry, enabled: false)

      conn = call(opts, "traced", %{}, meta)

      # The tool's own span is still there; Sake's is not, and the tool
      # runs outside the client's trace, without its baggage.
      assert %{"result" => %{"structuredContent" => %{"baggage" => %{}}}} =
               ModernClient.json(conn)

      %{"inside the tool" => inside} = Spans.await(["inside the tool"])
      assert inside.parent_span_id == :undefined
      Spans.refute_spans()
    end
  end
end
