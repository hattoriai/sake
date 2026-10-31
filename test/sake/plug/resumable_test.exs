defmodule Sake.Plug.ResumableTest do
  # Resumable SSE streams on legacy sessions (issue #101, "Resumability and
  # Redelivery" of revisions 2025-03-26 to 2025-11-25): event IDs, the
  # priming event and `retry`, replay after a dropped connection through a
  # GET with `Last-Event-ID`, the buffer's limits, the 2025-11-25 polling
  # pattern, the pubsub relay, and the client's side of it all.
  use ExUnit.Case, async: false

  alias Sake.Client.Transport
  alias Sake.Plug.Streams
  alias SakeTest.HTTP

  defmodule Count do
    @moduledoc false
    use Sake.Tool, name: "count", description: "Counts, with progress", stream: true

    arg :n, :integer, default: 3
    arg :delay_ms, :integer, default: 0

    @impl true
    def execute(%{n: n, delay_ms: d}, ctx) do
      for i <- 1..n do
        Process.sleep(d)
        ctx.progress.(i, {n, nil})
      end

      {:ok, "counted to #{n}"}
    end
  end

  defmodule Server do
    @moduledoc false
    use Sake.Server, name: "resumable", version: "1"

    tools [Count, SakeDev.Conformance.Tools.TestReconnection]
  end

  defmodule Router do
    @moduledoc false
    use Plug.Router
    plug :match
    plug :dispatch

    @secret String.duplicate("s", 64)

    forward "/mcp", to: Sake.Plug, init_opts: [server: Server, secret: @secret, sse_retry: 50]

    forward "/small",
      to: Sake.Plug,
      init_opts: [server: Server, secret: @secret, sse_buffer: [events: 2]]

    forward "/brief",
      to: Sake.Plug,
      init_opts: [server: Server, secret: @secret, sse_buffer: [age: 200]]

    forward "/plain",
      to: Sake.Plug,
      init_opts: [server: Server, secret: @secret, resumable: false]

    match _, do: send_resp(conn, 404, "")
  end

  setup do
    %{url: HTTP.start(Router)}
  end

  # ---- the wire

  defp initialize(url, revision \\ "2025-11-25") do
    resp =
      Req.post!(url,
        json:
          Sake.JSONRPC.request(0, "initialize", %{
            "protocolVersion" => revision,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "t", "version" => "0"}
          }),
        headers: [{"accept", "application/json, text/event-stream"}]
      )

    [session] = resp.headers["mcp-session-id"]

    [
      {"accept", "application/json, text/event-stream"},
      {"mcp-session-id", session},
      {"mcp-protocol-version", revision}
    ]
  end

  defp call(id, name, args \\ %{}) do
    Sake.JSONRPC.request(id, "tools/call", %{
      "name" => name,
      "arguments" => args,
      "_meta" => %{"progressToken" => "p"}
    })
  end

  # Opens a request whose SSE events come to this process, as
  # `{:fields, ref, [%{id:, retry:, data:}]}`; `{:done, ref, status, body}`
  # when the server ends the response. A raw HTTP/1.1 connection, which
  # `drop/1` resets: the server's next write fails, as on a client gone.
  defp open(method, url, headers, body \\ nil) do
    parent = self()
    ref = make_ref()
    uri = URI.parse(url)
    body = if body, do: JSON.encode!(body), else: ""

    request = [
      String.upcase(to_string(method)),
      " ",
      uri.path,
      " HTTP/1.1\r\nhost: localhost\r\ncontent-type: application/json\r\ncontent-length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "\r\n",
      body
    ]

    task =
      Task.async(fn ->
        {:ok, socket} =
          :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: true, packet: :raw])

        :ok = :gen_tcp.send(socket, request)

        receive_http(socket, parent, ref, %{
          phase: :head,
          buffer: "",
          sse: "",
          status: nil,
          body: ""
        })
      end)

    {task, ref}
  end

  defp receive_http(socket, parent, ref, state) do
    receive do
      {:tcp, ^socket, data} ->
        case http(%{state | buffer: state.buffer <> data}, parent, ref) do
          {:done, state} -> send(parent, {:done, ref, state.status, state.body})
          state -> receive_http(socket, parent, ref, state)
        end

      {:tcp_closed, ^socket} ->
        send(parent, {:done, ref, state.status, state.body})

      :drop ->
        :ok = :inet.setopts(socket, linger: {true, 0})
        :gen_tcp.close(socket)
    end
  end

  defp http(%{phase: :head, buffer: buffer} = state, parent, ref) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        [status_line | lines] = String.split(head, "\r\n")
        [_, status | _] = String.split(status_line, " ")

        headers =
          Map.new(lines, fn line ->
            [k, v] = String.split(line, ":", parts: 2)
            {String.downcase(k), String.trim(v)}
          end)

        phase =
          if headers["transfer-encoding"] == "chunked",
            do: :chunked,
            else: {:length, String.to_integer(headers["content-length"] || "0")}

        http(
          %{state | phase: phase, buffer: rest, status: String.to_integer(status)},
          parent,
          ref
        )

      [_] ->
        state
    end
  end

  defp http(%{phase: {:length, n}, buffer: buffer} = state, _parent, _ref) do
    if byte_size(buffer) >= n, do: {:done, %{state | body: buffer}}, else: state
  end

  defp http(%{phase: :chunked, buffer: buffer} = state, parent, ref) do
    with [size, rest] <- String.split(buffer, "\r\n", parts: 2),
         {size, _} = Integer.parse(size, 16),
         true <- byte_size(rest) >= size + 2 do
      if size == 0 do
        {:done, state}
      else
        <<chunk::binary-size(^size), "\r\n", rest::binary>> = rest
        http(%{chunk(state, chunk, parent, ref) | buffer: rest}, parent, ref)
      end
    else
      _ -> state
    end
  end

  defp chunk(%{status: 200} = state, data, parent, ref) do
    {fields, rest} = Transport.parse_sse_fields(state.sse <> data)
    if fields != [], do: send(parent, {:fields, ref, fields})
    %{state | sse: rest}
  end

  defp chunk(state, data, _parent, _ref), do: %{state | body: state.body <> data}

  # The fields received on `ref` until `until.(fields)` holds.
  defp read(ref, until, acc \\ []) do
    if acc != [] and until.(acc) do
      acc
    else
      receive do
        {:fields, ^ref, fields} -> read(ref, until, acc ++ fields)
        {:done, ^ref, 200, _body} -> acc
        {:done, ^ref, status, body} -> flunk("#{status}: #{inspect(body)} after #{inspect(acc)}")
      after
        5_000 -> flunk("timed out with #{inspect(acc)}")
      end
    end
  end

  defp all(ref), do: read(ref, fn _ -> false end)

  defp final?(fields, id), do: Enum.any?(fields, &match?(%{data: %{"id" => ^id}}, &1))

  defp progress(fields, n),
    do: Enum.any?(fields, &match?(%{data: %{"params" => %{"progress" => ^n}}}, &1))

  defp drop({task, _ref}) do
    send(task.pid, :drop)
    Task.await(task)
  end

  defp resume(url, headers, last), do: open(:get, url, [{"last-event-id", last} | headers])

  defp sid(id), do: id |> String.split(".") |> hd()

  # ---- the server

  test "a call's stream starts with a priming event and retry, and every event has an ID", %{
    url: url
  } do
    headers = initialize(url <> "/mcp")
    {_task, ref} = open(:post, url <> "/mcp", headers, call(1, "count", %{"n" => 2}))
    fields = all(ref)

    assert [%{id: prime, retry: 50, data: nil} | events] = fields
    assert prime =~ ~r/\A[\w-]+\.0\z/
    sid = sid(prime)

    assert Enum.map(events, & &1.id) == ["#{sid}.1", "#{sid}.2", "#{sid}.3"]

    assert %{data: %{"id" => 1, "result" => %{"content" => [%{"text" => "counted to 2"}]}}} =
             List.last(events)
  end

  test "an earlier revision gets retry but no ID in its first event (no empty event to number)",
       %{
         url: url
       } do
    headers = initialize(url <> "/mcp", "2025-06-18")
    {_task, ref} = open(:post, url <> "/mcp", headers, call(1, "count", %{"n" => 1}))

    assert [%{id: nil, retry: 50, data: nil}, %{id: id} | _] = all(ref)
    assert id =~ ~r/\.1\z/
  end

  test "after a dropped connection, a GET with Last-Event-ID gets the rest, then the stream ends",
       %{url: url} do
    url = url <> "/mcp"
    headers = initialize(url)
    stream = open(:post, url, headers, call(1, "count", %{"n" => 3, "delay_ms" => 100}))
    fields = read(elem(stream, 1), &progress(&1, 1))
    drop(stream)
    %{id: last} = List.last(fields)
    assert last =~ ~r/\.1\z/

    # The call went on without a connection.
    Process.sleep(400)
    {_task, ref} = resume(url, headers, last)
    sid = sid(last)

    assert [%{retry: 50, data: nil} | events] = all(ref)
    assert Enum.map(events, & &1.id) == ["#{sid}.2", "#{sid}.3", "#{sid}.4"]
    assert progress(events, 2) and progress(events, 3) and final?(events, 1)
  end

  test "a resumed stream goes on live", %{url: url} do
    url = url <> "/mcp"
    headers = initialize(url)
    stream = open(:post, url, headers, call(1, "count", %{"n" => 4, "delay_ms" => 150}))
    [%{id: prime} | _] = read(elem(stream, 1), &(&1 != []))
    drop(stream)

    {_task, ref} = resume(url, headers, prime)
    events = all(ref)
    assert progress(events, 1) and progress(events, 4) and final?(events, 1)
    assert Enum.map(events -- [hd(events)], & &1.id) == Enum.map(1..5, &"#{sid(prime)}.#{&1}")
  end

  test "an unknown, malformed or another session's Last-Event-ID is refused with a 400", %{
    url: url
  } do
    url = url <> "/mcp"
    headers = initialize(url)
    other = initialize(url)
    stream = open(:post, url, headers, call(1, "count", %{"n" => 2, "delay_ms" => 200}))
    [%{id: prime} | _] = read(elem(stream, 1), &(&1 != []))
    drop(stream)

    for last <- ["nope.1", "garbage", "#{sid(prime)}.x"] do
      resp = Req.get!(url, headers: [{"last-event-id", last} | headers], retry: false)
      assert resp.status == 400
      assert %{"error" => %{"message" => "Unknown or expired Last-Event-ID"}} = resp.body
    end

    # A future event of a real stream is unknown too.
    resp =
      Req.get!(url, headers: [{"last-event-id", sid(prime) <> ".99"} | headers], retry: false)

    assert resp.status == 400

    # The stream is the session's alone.
    resp = Req.get!(url, headers: [{"last-event-id", prime} | other], retry: false)
    assert resp.status == 400
  end

  test "the buffer keeps at most `events` events: an ID from before them is refused", %{url: url} do
    url = url <> "/small"
    headers = initialize(url)
    stream = open(:post, url, headers, call(1, "count", %{"n" => 5, "delay_ms" => 20}))
    [%{id: prime} | _] = read(elem(stream, 1), &(&1 != []))
    drop(stream)
    Process.sleep(300)
    sid = sid(prime)

    # Progress 1 to 3 were dropped; progress 5 and the response are kept.
    assert Req.get!(url, headers: [{"last-event-id", prime} | headers], retry: false).status ==
             400

    assert Req.get!(url, headers: [{"last-event-id", sid <> ".3"} | headers], retry: false).status ==
             400

    {_task, ref} = resume(url, headers, sid <> ".4")
    assert [%{retry: _}, %{id: id5}, %{id: id6} = final] = all(ref)
    assert {id5, id6} == {sid <> ".5", sid <> ".6"}
    assert final?([final], 1)
  end

  test "a stream with no connection for the buffer's age is gone", %{url: url} do
    url = url <> "/brief"
    headers = initialize(url)
    stream = open(:post, url, headers, call(1, "count", %{"n" => 1, "delay_ms" => 100}))
    [%{id: prime} | _] = read(elem(stream, 1), &(&1 != []))
    drop(stream)

    # Within the age, the stream is there; the GET then takes the response.
    {_task, ref} = resume(url, headers, prime)
    assert final?(all(ref), 1)

    stream = open(:post, url, headers, call(2, "count", %{"n" => 1, "delay_ms" => 50}))
    [%{id: prime} | _] = read(elem(stream, 1), &(&1 != []))
    drop(stream)
    Process.sleep(500)

    assert Req.get!(url, headers: [{"last-event-id", prime} | headers], retry: false).status ==
             400
  end

  test "polling: the handler closes the connection, and the client takes the response with GET",
       %{url: url} do
    url = url <> "/mcp"
    headers = initialize(url)
    {_task, ref} = open(:post, url, headers, call(1, "test_reconnection"))

    assert [%{id: prime, retry: 50, data: nil}] = all(ref)

    {_task, ref} = resume(url, headers, prime)
    events = all(ref)

    assert final?(events, 1)

    assert [%{data: %{"result" => %{"content" => [%{"text" => text}]}}}] =
             Enum.filter(events, & &1.data)

    assert text == "Reconnection test completed successfully"
  end

  test "the session's GET stream is resumable too", %{url: url} do
    url = url <> "/mcp"
    headers = initialize(url)
    stream = open(:get, url, headers)
    [%{id: prime, retry: 50}] = read(elem(stream, 1), &(&1 != []))

    Streams.broadcast(Server, {:list_changed, "tools"})

    [%{id: first, data: %{"method" => "notifications/tools/list_changed"}}] =
      read(elem(stream, 1), &(&1 != []))

    assert first == sid(prime) <> ".1"
    drop(stream)
    Process.sleep(50)

    # Missed while away.
    Streams.broadcast(Server, {:list_changed, "prompts"})
    Process.sleep(50)

    {task, ref} = resume(url, headers, first)

    assert [%{retry: 50}, %{id: id, data: %{"method" => "notifications/prompts/list_changed"}}] =
             read(ref, &(length(&1) >= 2))

    assert id == sid(prime) <> ".2"
    Task.shutdown(task, :brutal_kill)
  end

  test "resumable: false streams as before, without IDs", %{url: url} do
    url = url <> "/plain"
    headers = initialize(url)
    {_task, ref} = open(:post, url, headers, call(1, "count", %{"n" => 2}))
    fields = all(ref)

    assert final?(fields, 1)
    assert Enum.all?(fields, &(&1.id == nil and &1.retry == nil))
  end

  test "init validates the buffer's options" do
    assert_raise ArgumentError, fn -> Sake.Plug.init(server: Server, sse_buffer: [events: 0]) end
    assert_raise ArgumentError, fn -> Sake.Plug.init(server: Server, sse_buffer: [age: -1]) end
  end

  describe "on another node (the pubsub relay)" do
    setup do
      pubsub = :"sake_resumable_test_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Streams.Relay, pubsub})
      on_exit(fn -> :persistent_term.erase({Streams, :pubsub}) end)

      test = self()

      start_supervised!(
        {Task,
         fn ->
           :ok = Phoenix.PubSub.subscribe(pubsub, Streams.topic())
           send(test, :listening)
           forward(test)
         end}
      )

      assert_receive :listening
      %{pubsub: pubsub}
    end

    defp forward(test) do
      receive do
        message -> send(test, {:published, message})
      end

      forward(test)
    end

    test "a GET that reached another node gets the stream held here", %{url: url, pubsub: pubsub} do
      url = url <> "/mcp"
      headers = initialize(url)
      stream = open(:post, url, headers, call(1, "count", %{"n" => 2, "delay_ms" => 100}))
      [%{id: prime} | _] = read(elem(stream, 1), &(&1 != []))
      drop(stream)
      sid = sid(prime)
      [{_pid, nonce}] = Registry.lookup(Streams, {:sake_sse, sid})

      # The other node's connection listens on its topic and asks.
      topic = "sake:sse:test"
      :ok = Phoenix.PubSub.subscribe(pubsub, topic)

      Phoenix.PubSub.broadcast(
        pubsub,
        Streams.topic(),
        {:sake_resume, :other@node, sid, nonce, 0, topic}
      )

      assert_receive {:sake_sse_found, ^sid}, 1_000

      assert_receive {:sake_sse, ^sid, {:event, 1, %{"method" => "notifications/progress"}}},
                     1_000

      assert_receive {:sake_sse, ^sid, {:event, 3, %{"id" => 1, "result" => _}}}, 1_000
      assert_receive {:sake_sse, ^sid, :close}, 1_000
    end

    test "another session's nonce finds nothing", %{url: url, pubsub: pubsub} do
      url = url <> "/mcp"
      headers = initialize(url)
      stream = open(:post, url, headers, call(1, "count", %{"n" => 1, "delay_ms" => 200}))
      [%{id: prime} | _] = read(elem(stream, 1), &(&1 != []))
      drop(stream)
      sid = sid(prime)

      :ok = Phoenix.PubSub.subscribe(pubsub, "sake:sse:other")

      Phoenix.PubSub.broadcast(
        pubsub,
        Streams.topic(),
        {:sake_resume, :other@node, sid, "another-nonce", 0, "sake:sse:other"}
      )

      refute_receive {:sake_sse_found, _}, 300
    end

    test "a GET here for a stream held on another node gets its events through the relay", %{
      url: url,
      pubsub: pubsub
    } do
      url = url <> "/mcp"
      headers = initialize(url)
      {_task, ref} = resume(url, headers, "elsewhere.1")

      me = node()
      assert_receive {:published, {:sake_resume, ^me, "elsewhere", _nonce, 1, topic}}, 1_000

      # The other node's stream: found, the events after 1, then the end.
      Phoenix.PubSub.broadcast(
        pubsub,
        topic,
        {:sake_sse, "elsewhere",
         {:event, 2, Sake.JSONRPC.notification("notifications/message", %{})}}
      )

      Phoenix.PubSub.broadcast(pubsub, topic, {:sake_sse_found, "elsewhere"})

      Phoenix.PubSub.broadcast(
        pubsub,
        topic,
        {:sake_sse, "elsewhere", {:event, 3, Sake.JSONRPC.result(1, %{"content" => []})}}
      )

      Phoenix.PubSub.broadcast(pubsub, topic, {:sake_sse, "elsewhere", :close})

      assert [%{retry: _}, %{id: "elsewhere.2"}, %{id: "elsewhere.3"}] = all(ref)
      assert_receive {:published, {:sake_detach_sse, ^me, "elsewhere", ^topic}}
    end
  end

  # ---- the client

  describe "Sake.Client" do
    test "takes the response of a call whose stream the server closed (polling)", %{url: url} do
      {:ok, session} =
        Sake.Client.connect(url <> "/mcp", legacy_version: "2025-11-25", era: :legacy)

      {:ok, result, _session} = Sake.Client.call_tool(session, "test_reconnection", %{})
      assert [%Sake.Content{text: "Reconnection test completed successfully"}] = result.content
    end

    test "waits retry, resumes with Last-Event-ID, and reads the rest of the stream" do
      url = HTTP.start({SakeTest.ResumableFake, %{mode: :resume, test: self()}})
      {:ok, session} = Sake.Client.connect(url, era: :legacy)
      {:ok, result, _session} = Sake.Client.call_tool(session, "t", %{})

      assert [%Sake.Content{text: "resumed"}] = result.content
      assert_receive {:get, "e1", waited}
      assert waited >= 150
    end

    test "gives up after max_reconnects attempts without an event" do
      url = HTTP.start({SakeTest.ResumableFake, %{mode: :close, test: self()}})
      {:ok, session} = Sake.Client.connect(url, era: :legacy, max_reconnects: 2)

      assert {:error, :stream_lost, _session} = Sake.Client.call_tool(session, "t", %{})
      assert_receive {:get, "e1", _}
      assert_receive {:get, "e1", _}
      refute_receive {:get, _, _}, 300
    end

    test "a refused resumption ends the call with the server's error" do
      url = HTTP.start({SakeTest.ResumableFake, %{mode: :refuse, test: self()}})
      {:ok, session} = Sake.Client.connect(url, era: :legacy)

      assert {:error, {:http, 400, %{"error" => _}}, _session} =
               Sake.Client.call_tool(session, "t", %{})
    end

    test "parses IDs, retry, and events without data" do
      {fields, ""} =
        Transport.parse_sse_fields(
          "id: a\nretry: 10\ndata: \n\n: comment\n\nid: b\ndata: {\"x\":1}\n\nretry: z\n\n"
        )

      assert fields == [
               %{id: "a", retry: 10, data: nil},
               %{id: "b", retry: nil, data: %{"x" => 1}}
             ]
    end
  end
end

defmodule SakeTest.ResumableFake do
  @moduledoc false
  # A legacy server that closes a call's stream after its priming event
  # (`retry: 200`), as the conformance suite's does: `:resume` answers the
  # GET with a notification and the response, `:close` closes the GET too, `:refuse` answers it with a 400.
  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "GET"} = conn, %{test: test, mode: mode}) do
    [last] = get_req_header(conn, "last-event-id")
    waited = System.monotonic_time(:millisecond) - :persistent_term.get({__MODULE__, :closed})
    send(test, {:get, last, waited})
    :persistent_term.put({__MODULE__, :closed}, System.monotonic_time(:millisecond))

    case mode do
      :refuse ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, JSON.encode!(Sake.JSONRPC.error(nil, -32_600, "Unknown")))

      :close ->
        conn |> sse() |> event("retry: 50\n\n")

      :resume ->
        conn
        |> sse()
        |> event(
          "id: e2\ndata: #{JSON.encode!(Sake.JSONRPC.notification("notifications/message", %{"level" => "info", "data" => "x"}))}\n\n"
        )
        |> event(
          "id: e3\ndata: #{JSON.encode!(Sake.JSONRPC.result(:persistent_term.get({__MODULE__, :call}), %{"content" => [%{"type" => "text", "text" => "resumed"}]}))}\n\n"
        )
    end
  end

  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    message = JSON.decode!(body)

    case message do
      %{"method" => "initialize", "id" => id} ->
        json(
          conn,
          Sake.JSONRPC.result(id, %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "fake", "version" => "0"}
          })
        )

      %{"method" => "tools/call", "id" => id} ->
        :persistent_term.put({__MODULE__, :call}, id)
        :persistent_term.put({__MODULE__, :closed}, System.monotonic_time(:millisecond))
        conn |> sse() |> event("id: e1\nretry: 200\ndata: \n\n")

      %{"id" => id, "method" => _} ->
        json(conn, Sake.JSONRPC.result(id, %{}))

      _ ->
        send_resp(conn, 202, "")
    end
  end

  defp json(conn, body) do
    conn
    |> put_resp_header("mcp-session-id", "s1")
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(body))
  end

  defp sse(conn) do
    conn
    |> put_resp_header("mcp-session-id", "s1")
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)
  end

  defp event(conn, chunk) do
    {:ok, conn} = chunk(conn, chunk)
    conn
  end
end
