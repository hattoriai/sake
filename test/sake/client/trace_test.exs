defmodule Sake.Client.TraceTest do
  # A trace from a client's span through Sake.Client, the server and the
  # tool, as the OpenTelemetry SDK records it, over HTTP and stdio.
  use ExUnit.Case, async: false

  alias Sake.Client
  alias SakeTest.{HTTP, Spans}

  setup do
    Application.ensure_all_started(:req)
    Spans.capture()

    plug =
      {Sake.Plug,
       Sake.Plug.init(server: SakeTest.TracedServer, secret: String.duplicate("s", 64))}

    %{url: HTTP.start(plug) <> "/mcp"}
  end

  # The client's and the server's spans of one name.
  defp by_kind(spans) do
    spans |> List.wrap() |> Enum.group_by(& &1.kind)
  end

  defp child_of?(span, %{span_id: parent_id, trace_id: trace_id}),
    do: span.trace_id == trace_id and span.parent_span_id == parent_id

  defp child_of?(span, span_ctx),
    do: child_of?(span, %{span_id: Spans.span_id(span_ctx), trace_id: Spans.trace_id(span_ctx)})

  # Runs `fun` under the test's own span, with baggage, and returns the
  # span's context.
  defp agent(fun) do
    {result, root} =
      Spans.root("agent", fn ->
        :otel_baggage.set("user", "ana")
        fun.()
      end)

    :otel_baggage.clear()
    {result, root}
  end

  for era <- [:modern, :legacy] do
    describe "#{era}" do
      @era era

      test "one trace from the client's span to the span inside the tool", %{url: url} do
        {{result, session}, root} =
          agent(fn ->
            {:ok, session} = Client.connect(url, era: @era)
            {:ok, result, session} = Client.call_tool(session, "traced", %{})
            {result, session}
          end)

        # The baggage of the client's context reached the tool.
        assert result.structured == %{"baggage" => %{"user" => "ana"}}

        spans = Spans.await(["tools/call traced", "tools/call traced", "inside the tool"])
        %{client: [client], server: [server]} = by_kind(spans["tools/call traced"])
        inside = spans["inside the tool"]

        assert child_of?(client, root)
        assert child_of?(server, client)
        assert child_of?(inside, server)

        assert client.attributes["jsonrpc.request.id"] == server.attributes["jsonrpc.request.id"]
        assert client.attributes["mcp.protocol.version"] == session.revision
        assert server.attributes["mcp.protocol.version"] == session.revision
        assert client.attributes["gen_ai.tool.name"] == "traced"
        assert client.attributes["gen_ai.operation.name"] == "execute_tool"
        assert client.attributes["network.transport"] == "tcp"
        assert client.attributes["server.address"] == "127.0.0.1"
        assert client.attributes["server.port"] == URI.parse(url).port
        assert client.status == :unset

        if @era == :legacy,
          do: assert(client.attributes["mcp.session.id"] == session.session_id),
          else: refute(Map.has_key?(client.attributes, "mcp.session.id"))
      end
    end
  end

  test "connecting is a request of its own, in the same trace", %{url: url} do
    {_, root} = agent(fn -> {:ok, _} = Client.connect(url, era: :legacy) end)

    %{"initialize" => initialize} = Spans.await(["initialize", "initialize"])
    %{client: [client], server: [server]} = by_kind(initialize)

    assert child_of?(client, root)
    assert child_of?(server, client)
    assert client.attributes["mcp.protocol.version"] == "2025-11-25"
    assert server.attributes["mcp.protocol.version"] == "2025-11-25"
  end

  test "a retry with the client's input is a request under the call's span", %{url: url} do
    on_input = fn _requests, _session ->
      %{"who" => %{"action" => "accept", "content" => %{"name" => "Ana"}}}
    end

    {_, root} =
      agent(fn ->
        {:ok, session} = Client.connect(url, era: :modern, on_input: on_input)
        {:ok, %{text: "Hello, Ana!"}, _} = Client.call_tool(session, "confirm", %{})
      end)

    names = List.duplicate("tools/call confirm", 4)
    %{client: clients, server: servers} = by_kind(Spans.await(names)["tools/call confirm"])

    [call, retry] = Enum.sort_by(clients, & &1.attributes["jsonrpc.request.id"])
    [asked, answered] = Enum.sort_by(servers, & &1.attributes["jsonrpc.request.id"])

    assert child_of?(call, root)
    assert child_of?(asked, call)
    assert child_of?(retry, call)
    assert child_of?(answered, retry)
  end

  test "a task: the polls are under the call's span, the run under the server's", %{url: url} do
    {_, root} =
      agent(fn ->
        {:ok, session} = Client.connect(url, era: :modern)
        {:ok, %{text: "done"}, _} = Client.call_tool(session, "traced_task", %{})
      end)

    spans =
      Spans.await([
        "tools/call traced_task",
        "tools/call traced_task",
        "execute_tool traced_task",
        "inside the task",
        "tasks/get",
        "tasks/get"
      ])

    %{client: [call], server: [server]} = by_kind(spans["tools/call traced_task"])
    %{client: [poll | _], server: [polled | _]} = by_kind(spans["tasks/get"])
    run = spans["execute_tool traced_task"]

    assert child_of?(call, root)
    assert child_of?(server, call)
    assert child_of?(run, server)
    assert child_of?(spans["inside the task"], run)
    assert child_of?(poll, call)
    assert polled.trace_id == call.trace_id
    assert call.status == :unset
  end

  describe "errors" do
    test "a tool error and a JSON-RPC error are errors of the client's span", %{url: url} do
      agent(fn ->
        {:ok, session} = Client.connect(url, era: :modern)
        {:ok, %{is_error: true}, session} = Client.call_tool(session, "failing", %{})
        {:error, {:rpc, _}, _} = Client.call_tool(session, "nope", %{})
      end)

      spans =
        Spans.await([
          "tools/call failing",
          "tools/call failing",
          "tools/call nope",
          "tools/call nope"
        ])

      %{client: [failing]} = by_kind(spans["tools/call failing"])
      %{client: [client], server: [server]} = by_kind(spans["tools/call nope"])

      assert failing.attributes["error.type"] == "tool_error"
      assert {:error, _} = failing.status

      # Every error code is an error for the client; for the server an
      # unknown tool is the caller's mistake.
      assert client.attributes["rpc.response.status_code"] == "-32602"
      assert client.attributes["error.type"] == "-32602"
      assert client.status == {:error, "Unknown tool: nope"}
      assert server.status == :unset
    end

    test "a transport error is named by the exception's module" do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      agent(fn ->
        assert {:error, _} = Client.connect("http://127.0.0.1:#{port}/mcp", era: :modern)
      end)

      %{"server/discover" => span} = Spans.await(["server/discover"])
      assert span.kind == :client
      assert span.attributes["error.type"] == "Req.TransportError"
      assert {:error, _} = span.status
    end
  end

  test "the trace context joins the protocol's own fields in _meta" do
    {params, root} =
      Spans.root("agent", fn ->
        Sake.Trace.inject(%{
          "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
        })
      end)

    assert params["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
    assert params["_meta"]["traceparent"] == Spans.traceparent(root)
    assert Sake.Trace.inject(%{}) == %{}
  end

  test "telemetry: [:sake, :client, :request] for every request", %{url: url} do
    test = self()
    handler = "client-request-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:sake, :client, :request, :stop],
      fn _event, %{duration: duration}, meta, _ -> send(test, {:stop, duration, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, session} = Client.connect(url, era: :modern)
    {:ok, _, _} = Client.call_tool(session, "failing", %{})

    assert_receive {:stop, _, %{method: "server/discover", error_type: nil, transport: :http}}

    assert_receive {:stop, duration,
                    %{method: "tools/call", error_type: "tool_error", era: :modern}}

    assert duration > 0
  end

  test "stdio: the server in another process continues the client's trace" do
    path = Path.join(System.tmp_dir!(), "sake-spans-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    {_, root} =
      agent(fn ->
        {:ok, session} = Client.connect(stdio("traced", [path]), era: :modern)
        {:ok, _, session} = Client.call_tool(session, "traced", %{})
        :ok = Client.close(session)
      end)

    %{"tools/call traced" => client} = Spans.await(["tools/call traced"])
    assert client.attributes["network.transport"] == "pipe"
    assert child_of?(client, root)

    server_spans = path |> File.read!() |> :erlang.binary_to_term()
    server = Enum.find(server_spans, &(&1.name == "tools/call traced"))
    inside = Enum.find(server_spans, &(&1.name == "inside the tool"))

    assert server.kind == :server
    assert child_of?(server, client)
    assert child_of?(inside, server)
    assert server.attributes["network.transport"] == "pipe"
  end

  test "Sake.Test: the in-memory server continues the client's trace, on both eras" do
    for era <- [:modern, :legacy] do
      {_, root} =
        agent(fn ->
          client = Sake.Test.connect(SakeTest.TracedServer, era: era)

          {:ok, %{structured: %{"baggage" => %{"user" => "ana"}}}} =
            Sake.Test.call_tool(client, "traced")
        end)

      spans = Spans.await(["tools/call traced", "tools/call traced", "inside the tool"])
      %{client: [client], server: [server]} = by_kind(spans["tools/call traced"])

      assert child_of?(client, root)
      assert child_of?(server, client)
      assert child_of?(spans["inside the tool"], server)
      assert client.attributes["network.transport"] == "inproc"
      assert server.attributes["network.transport"] == "inproc"
    end
  end

  defp stdio(name, args) do
    paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])

    {:stdio, System.find_executable("elixir"),
     paths ++ [Path.expand("../../support/stdio/#{name}.exs", __DIR__) | args]}
  end
end
