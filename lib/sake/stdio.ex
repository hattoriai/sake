defmodule Sake.Stdio do
  @moduledoc """
  Serves a `Sake.Server` over standard input and output, for a client that
  launches the server as a subprocess:

      Sake.Stdio.run(MyApp.MCP)

  `run/2` blocks until standard input closes. In a supervision tree, start
  it as a child instead, after `Sake`:

      {Sake.Stdio, server: MyApp.MCP}

  From a Mix project, `mix sake.stdio MyApp.MCP` does the same.

  Options: `server:` (the child's, required), `scope:` (the host's
  principal: a value, or a function of no arguments called for every
  request; default `nil`), `secret:` (binary or `{m, f, a}`; default the
  `Sake` configuration, else a random secret for the life of the process),
  `reraise:` (re-raise tool exceptions, for tests), `grace:` (ms that
  requests still running when standard input closes get to finish,
  default 2 000), `halt:` (the child's only: stop the VM once standard
  input closes, default `true`), `input:` and `output:` (IO devices,
  default standard input and output).

  The server speaks both eras on the one connection. A request whose
  `_meta` names the modern revision is served statelessly; an `initialize`
  request opens the connection's legacy session, and requests without a
  protocol version in `_meta` then belong to it. Each request runs in its
  own process, so responses can arrive out of order;
  `notifications/cancelled` stops a request and suppresses its response.

  There is no authorization on stdio: the client that launched the server
  already holds its credentials, and the server takes its own from its
  environment. Pass the principal as `scope:`.

  Standard output carries MCP messages only. While serving it, Sake moves
  the default `Logger` handler to standard error and runs every request
  with standard error as its group leader, so `IO.puts/1` in a tool cannot
  break the stream.
  """

  use GenServer
  require Logger

  alias Sake.{Context, JSONRPC, Protocol}
  alias Sake.Plug.{Stream, Streams}
  alias Sake.Server.{Dispatch, Legacy}

  # `loop/3` demonitors the task's monitor ref by hand, exactly as
  # `Sake.Plug.Stream` does; see the note there.
  @dialyzer {:no_opaque, loop: 3}

  @grace 2_000

  @doc "Serves `server` until standard input (or `input:`) closes."
  @spec run(module(), keyword()) :: :ok
  def run(server, opts \\ []) do
    {:ok, pid} = start_link(Keyword.merge(opts, server: server, halt: false))
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Moves the default `Logger` handler from standard output to standard
  error. `run/2` and the child do this when they serve standard output; a
  release that logs while it boots should also configure it:

      config :logger, :default_handler, config: [type: :standard_error]
  """
  @spec log_to_stderr() :: :ok
  def log_to_stderr do
    case :logger.get_handler_config(:default) do
      {:ok, %{module: :logger_std_h, config: %{type: :standard_io} = config} = handler} ->
        :ok = :logger.remove_handler(:default)

        :ok =
          :logger.add_handler(:default, :logger_std_h, %{
            handler
            | config: %{config | type: :standard_error}
          })

      _ ->
        :ok
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    server = opts[:server] || raise(ArgumentError, "Sake.Stdio needs a server: option")
    standard? = opts[:output] in [nil, :stdio]
    input = device(opts[:input])
    output = device(opts[:output])

    if standard? do
      log_to_stderr()
      :ok = :io.setopts(input, binary: true, encoding: :unicode)
    end

    ensure_streams()
    me = self()

    {:ok,
     %{
       server: server,
       scope: opts[:scope],
       secret: secret(opts[:secret]),
       reraise: opts[:reraise] || false,
       grace: opts[:grace] || @grace,
       halt: Keyword.get(opts, :halt, true),
       output: output,
       group_leader: if(standard?, do: Process.whereis(:standard_error)),
       reader: spawn_link(fn -> read(input, me) end),
       requests: %{},
       pids: %{},
       session: nil,
       nonce: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false),
       subscribed: %{},
       closing: false
     }}
  end

  defp device(nil), do: Process.group_leader()
  defp device(:stdio), do: Process.group_leader()
  defp device(device), do: device

  # Cursors and request states only ever travel between this process and
  # its one client, so a random secret serves when the host has none.
  defp secret(nil), do: Sake.Secret.configured() || :crypto.strong_rand_bytes(32)
  defp secret(secret), do: Sake.Secret.resolve(secret)

  # The stream registry runs under the host's `Sake` supervisor; a server
  # started on its own (a script, `mix sake.stdio`) starts one here.
  defp ensure_streams do
    unless Process.whereis(Streams) do
      {:ok, _} = Supervisor.start_link([Streams.child_spec([])], strategy: :one_for_one)
    end
  end

  defp read(input, conn) do
    case IO.read(input, :line) do
      line when is_binary(line) ->
        send(conn, {:sake_stdio_line, line})
        read(input, conn)

      _eof_or_error ->
        send(conn, :sake_stdio_eof)
    end
  end

  # ---- input

  @impl true
  def handle_info({:sake_stdio_line, line}, state) do
    case String.trim_trailing(line) do
      "" -> {:noreply, state}
      json -> json |> decode() |> message(state)
    end
  end

  def handle_info(:sake_stdio_eof, %{closing: true} = state), do: {:noreply, state}

  # Standard input closed: open subscriptions end gracefully, requests in
  # flight get the grace period to finish, and then the server stops.
  def handle_info(:sake_stdio_eof, state) do
    for {_id, {pid, :listen}} <- state.requests, do: send(pid, :sake_shutdown)
    Process.send_after(self(), :sake_stdio_deadline, state.grace)
    stop_when_idle(%{state | closing: true})
  end

  def handle_info(:sake_stdio_deadline, state) do
    for {_id, {pid, _kind}} <- state.requests, do: Process.exit(pid, :kill)
    {:stop, :normal, state}
  end

  # ---- output of the request processes

  def handle_info({:sake_stdio_send, id, message}, state) do
    if Map.has_key?(state.requests, id), do: write(state, message)
    {:noreply, state}
  end

  def handle_info({:sake_stdio_reply, id, message}, state) do
    case Map.pop(state.requests, id) do
      {nil, _requests} ->
        {:noreply, state}

      {{pid, _kind}, requests} ->
        if message, do: write(state, message)
        stop_when_idle(%{state | requests: requests, pids: Map.delete(state.pids, pid)})
    end
  end

  # ---- the legacy session's notifications

  def handle_info({:sake_notify, {:list_changed, kind}}, state) do
    write(state, JSONRPC.notification("notifications/#{kind}/list_changed"))
    {:noreply, state}
  end

  def handle_info({:sake_notify, {:resource_updated, uri}}, state) do
    if Map.has_key?(state.subscribed, uri),
      do: write(state, JSONRPC.notification("notifications/resources/updated", %{"uri" => uri}))

    {:noreply, state}
  end

  # ---- processes

  def handle_info({:EXIT, pid, reason}, %{reader: pid} = state) do
    if reason == :normal, do: {:noreply, state}, else: handle_info(:sake_stdio_eof, state)
  end

  # A request process that exits without its reply failed outside the
  # handler (the handler's own failures become JSON-RPC errors in the
  # task): the client still gets an answer.
  def handle_info({:EXIT, pid, reason}, state) do
    case Map.pop(state.pids, pid) do
      {nil, _pids} ->
        {:noreply, state}

      {id, pids} ->
        Logger.error("Sake.Stdio request failed: #{inspect(reason)}")
        state = %{state | pids: pids, requests: Map.delete(state.requests, id)}

        unless match?({:batch, _}, id),
          do: write(state, JSONRPC.error(id, JSONRPC.code(:internal), "The request failed"))

        stop_when_idle(state)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(:normal, %{halt: true}), do: System.stop(0)
  def terminate(_reason, _state), do: :ok

  defp stop_when_idle(%{closing: true, requests: requests} = state)
       when map_size(requests) == 0,
       do: {:stop, :normal, state}

  defp stop_when_idle(state), do: {:noreply, state}

  defp decode(json) do
    with {:ok, term} <- JSON.decode(json),
         {:ok, parsed} <- parse(term),
         :ok <- Sake.Plug.shape(parsed) do
      {:ok, parsed}
    end
  end

  defp parse(term) do
    case JSONRPC.parse(term) do
      {:error, :malformed} -> {:error, :malformed}
      parsed -> {:ok, parsed}
    end
  end

  defp message({:ok, parsed}, state), do: handle(parsed, state)

  defp message({:error, :malformed}, state),
    do: reply(state, JSONRPC.error(nil, JSONRPC.code(:invalid_request), "Invalid request"))

  # A notification has no one to answer an error to.
  defp message({:error, :params, nil, _message}, state), do: {:noreply, state}

  defp message({:error, :params, id, message}, state),
    do: reply(state, JSONRPC.error(id, JSONRPC.code(:invalid_params), message))

  defp message({:error, _json}, state),
    do: reply(state, JSONRPC.error(nil, JSONRPC.code(:parse_error), "Parse error"))

  defp reply(state, message) do
    write(state, message)
    {:noreply, state}
  end

  defp write(state, message), do: IO.write(state.output, [JSON.encode!(message), ?\n])

  # ---- messages

  defp handle({:request, id, _method, _params}, state) when is_map_key(state.requests, id),
    do:
      reply(state, JSONRPC.error(id, JSONRPC.code(:invalid_request), "Request id already in use"))

  defp handle({:request, _id, "initialize", _params} = parsed, state),
    do: initialize(parsed, state)

  defp handle({:request, id, _method, params} = parsed, state) do
    meta = params["_meta"] || %{}

    case meta[Protocol.meta(:protocol_version)] do
      nil when state.session == nil ->
        reply(state, JSONRPC.error(id, JSONRPC.code(:invalid_request), "Not initialized"))

      nil ->
        legacy(parsed, state)

      version ->
        if Protocol.era(version) == :modern,
          do: modern(parsed, meta, version, state),
          else:
            reply(
              state,
              JSONRPC.error(
                id,
                JSONRPC.code(:unsupported_version),
                "Unsupported protocol version",
                %{"supported" => Protocol.supported(), "requested" => version}
              )
            )
    end
  end

  defp handle({:notification, "notifications/cancelled", %{"requestId" => id}}, state),
    do: cancel(id, state)

  defp handle({:notification, _method, _params}, state), do: {:noreply, state}

  # A legacy client's answer to a request a handler sent it.
  defp handle({:response, id, result}, state) do
    _ = Streams.deliver_response(id, {:ok, result})
    {:noreply, state}
  end

  defp handle({:error_response, id, error}, state) do
    _ = Streams.deliver_response(id, {:error, error})
    {:noreply, state}
  end

  defp handle({:batch, items}, %{session: %{revision: "2025-03-26"}} = state) do
    ctx = legacy_context(state)
    scope = state.scope

    start(state, {:batch, make_ref()}, :request, fn _conn ->
      case Sake.Plug.batch_replies(items, %{ctx | scope: scope(scope)}) do
        [] -> nil
        replies -> replies
      end
    end)
  end

  defp handle({:batch, _items}, state),
    do:
      reply(state, JSONRPC.error(nil, JSONRPC.code(:invalid_request), "Batches are not accepted"))

  defp cancel(id, state) do
    case Map.pop(state.requests, id) do
      {nil, _requests} ->
        {:noreply, state}

      {{pid, _kind}, requests} ->
        send(pid, :sake_stdio_cancel)
        stop_when_idle(%{state | requests: requests, pids: Map.delete(state.pids, pid)})
    end
  end

  # ---- modern

  # The `_meta` checks of `Sake.Plug`, without the header layer stdio
  # does not have.
  defp modern({:request, id, method, params} = parsed, meta, version, state) do
    cond do
      not is_map(meta[Protocol.meta(:client_capabilities)]) ->
        reply(
          state,
          JSONRPC.error(
            id,
            JSONRPC.code(:invalid_params),
            "Missing #{Protocol.meta(:client_capabilities)} in _meta"
          )
        )

      not (is_nil(meta[Protocol.meta(:log_level)]) or
               Sake.Progress.level?(meta[Protocol.meta(:log_level)])) ->
        reply(state, JSONRPC.error(id, JSONRPC.code(:invalid_params), "Unknown log level"))

      method == "subscriptions/listen" ->
        server = state.server
        start(state, id, :listen, &listen(&1, server, id, params))

      true ->
        ctx =
          Context.new(
            era: :modern,
            protocol_version: version,
            client_info: map(meta[Protocol.meta(:client_info)]),
            client_capabilities: meta[Protocol.meta(:client_capabilities)],
            log_level: meta[Protocol.meta(:log_level)],
            trace: Map.take(meta, ["traceparent", "tracestate", "baggage"]),
            secret: state.secret,
            server: state.server,
            reraise: state.reraise
          )

        request(parsed, ctx, &Dispatch.handle/3, state)
    end
  end

  # ---- legacy

  defp initialize({:request, id, "initialize", params} = parsed, state) do
    ctx = Context.new(era: :legacy, secret: state.secret, server: state.server)

    case Legacy.handle(state.server, parsed, ctx) do
      {:initialize, revision, capabilities, result} ->
        if state.session == nil, do: Streams.register_legacy(state.server, state.nonce)

        session = %{
          revision: revision,
          capabilities: capabilities,
          client_info: map(params["clientInfo"]),
          log_level: nil
        }

        reply(%{state | session: session, subscribed: %{}}, JSONRPC.result(id, result))

      {:error, error} ->
        reply(state, %{"jsonrpc" => "2.0", "id" => id, "error" => error})
    end
  end

  # The methods that change the session run here, in order with the rest of
  # the input; every other request runs in its own process.
  defp legacy({:request, id, "logging/setLevel", params} = parsed, state) do
    outcome = Legacy.handle(state.server, parsed, legacy_context(state))

    state =
      if match?({:reply, _}, outcome),
        do: put_in(state.session.log_level, params["level"]),
        else: state

    reply(state, Stream.response(id, outcome))
  end

  defp legacy({:request, id, method, _params} = parsed, state)
       when method in ["resources/subscribe", "resources/unsubscribe"] do
    outcome = Legacy.handle(state.server, parsed, legacy_context(state))

    subscribed =
      case outcome do
        {:subscribe, uri} -> Map.put(state.subscribed, uri, true)
        {:unsubscribe, uri} -> Map.delete(state.subscribed, uri)
        _ -> state.subscribed
      end

    reply(%{state | subscribed: subscribed}, Stream.response(id, outcome))
  end

  defp legacy(parsed, state), do: request(parsed, legacy_context(state), &Legacy.handle/3, state)

  defp legacy_context(%{session: session} = state) do
    Context.new(
      era: :legacy,
      protocol_version: session.revision,
      client_info: session.client_info,
      client_capabilities: session.capabilities,
      log_level: session.log_level,
      secret: state.secret,
      server: state.server,
      reraise: state.reraise
    )
  end

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}

  # ---- request processes

  # Each request runs in a process of its own, linked to this one, which
  # relays the handler's progress, log messages and legacy elicitation
  # requests to the client while the handler runs in a task, as the SSE
  # loop of `Sake.Plug.Stream` does.
  defp request({:request, id, method, params} = parsed, ctx, handler, state) do
    meta = telemetry_meta(method, params, ctx)
    scope = state.scope

    start(state, id, :request, fn conn ->
      ctx = %{ctx | scope: scope(scope)}

      :telemetry.span([:sake, :server, :request], meta, fn ->
        {message, cancelled} = run(conn, parsed, ctx, handler)
        {message, Map.put(meta, :cancelled, cancelled)}
      end)
    end)
  end

  defp telemetry_meta(method, params, ctx) do
    %{
      method: method,
      component: params["name"] || params["uri"],
      era: ctx.era,
      protocol_version: ctx.protocol_version,
      client_name: ctx.client_info["name"]
    }
  end

  # The principal is computed in the request's own process, so a `scope:`
  # function that fails takes down that request, not the connection.
  defp scope(fun) when is_function(fun, 0), do: fun.()
  defp scope(value), do: value

  defp run(conn, {:request, id, _method, params} = parsed, ctx, handler) do
    me = self()
    token = get_in(params, ["_meta", "progressToken"])

    progress =
      if token,
        do: fn current, {total, message} ->
          send(me, {:sake_progress, token, current, total, message})
        end,
        else: fn _, _ -> :ok end

    ctx = %{ctx | progress: progress, transport: me}
    task = Task.async(fn -> Stream.run_safely(parsed, ctx, handler) end)
    loop(conn, id, task)
  end

  @spec loop(pid(), JSONRPC.id(), Task.t()) :: {map() | nil, boolean()}
  defp loop(conn, id, task) do
    %Task{ref: task_ref} = task

    receive do
      {:sake_progress, token, current, total, message} ->
        send(conn, {:sake_stdio_send, id, Stream.progress(token, current, total, message)})
        loop(conn, id, task)

      {:sake_log, level, data} ->
        send(conn, {:sake_stdio_send, id, Stream.log(level, data)})
        loop(conn, id, task)

      {:sake_elicit, _from, request_id, params} ->
        # Legacy elicitation: the server asks the client and the handler
        # waits; the client's response comes back through `Streams`.
        message = JSONRPC.request(request_id, "elicitation/create", params)
        send(conn, {:sake_stdio_send, id, message})
        loop(conn, id, task)

      :sake_stdio_cancel ->
        Task.shutdown(task, :brutal_kill)
        {nil, true}

      {^task_ref, outcome} ->
        Process.demonitor(task_ref, [:flush])
        {Stream.response(id, outcome), false}

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        {JSONRPC.error(id, JSONRPC.code(:internal), "The request failed: #{inspect(reason)}"),
         false}
    end
  end

  # A `subscriptions/listen` stream: acknowledged, then the events its
  # filter asks for, tagged with its subscription ID, until the client
  # cancels it or the server stops.
  defp listen(conn, server, id, params) do
    honoured = Stream.honoured(params)
    Streams.register_listen(server, id, honoured)
    meta = %{Protocol.meta(:subscription_id) => id}
    send(conn, {:sake_stdio_send, id, Stream.acknowledged(honoured, meta)})
    listen_loop(conn, server, id, honoured, meta)
  end

  defp listen_loop(conn, server, id, honoured, meta) do
    receive do
      {:sake_notify, event} ->
        if message = Stream.notification_for(event, honoured, meta),
          do: send(conn, {:sake_stdio_send, id, message})

        listen_loop(conn, server, id, honoured, meta)

      :sake_shutdown ->
        Streams.unregister_listen(server)
        JSONRPC.result(id, %{"resultType" => "complete", "_meta" => meta})

      :sake_stdio_cancel ->
        nil
    end
  end

  # Starts `fun` in a process of its own, linked to this one, tracked under
  # `key` until it hands back its final message (or nil, for none).
  defp start(state, key, kind, fun) do
    conn = self()
    group_leader = state.group_leader

    pid =
      spawn_link(fn ->
        if group_leader, do: Process.group_leader(self(), group_leader)
        send(conn, {:sake_stdio_reply, key, fun.(conn)})
      end)

    {:noreply,
     %{
       state
       | requests: Map.put(state.requests, key, {pid, kind}),
         pids: Map.put(state.pids, pid, key)
     }}
  end
end
