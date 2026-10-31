defmodule Sake.Plug.Resumable do
  @moduledoc false
  # A resumable SSE stream of a legacy session (revisions 2025-03-26 to
  # 2025-11-25, "Resumability and Redelivery"): a process that outlives
  # the HTTP connection carrying the stream.
  #
  # It owns what the stream carries: a call's handler (a POST's stream),
  # or the session's notifications (a GET's). It numbers each event, keeps
  # the last ones in a bounded buffer (a count and an age), and forwards
  # them to the connection attached to it, if any. When that connection
  # drops, the call goes on and its events are kept; a GET with
  # `Last-Event-ID` attaches a new connection (on this node, or on another
  # through the `pubsub:` relay), which gets the events after that ID, then
  # the live ones. The stream's ID is the event ID's prefix: `<sid>.<n>`.
  #
  # A stream ends when its call's response was delivered (the connection is
  # closed after it), or when no connection has been attached for the
  # buffer's age.

  use GenServer

  require Logger

  alias Sake.JSONRPC
  alias Sake.Plug.Streams

  @registry Sake.Plug.Streams

  @typedoc "Where the stream's events go: a connection process here, or a pubsub topic."
  @type subscriber :: {:pid, pid()} | {:topic, String.t()}

  # ---- starting

  @doc """
  Starts the stream of a call, with `subscriber` (the POST's connection)
  attached before the handler runs, so that it misses nothing, not even a
  request to close it: `fun` runs the handler (bound to the request's
  trace, so it takes no argument: it finds this process with `owner/0`),
  with this process as its transport, so its progress, log messages and
  questions to the client are events of the stream.
  """
  @spec start_call(map(), String.t(), (-> term()), term(), subscriber()) ::
          {:ok, pid(), String.t()}
  def start_call(opts, nonce, fun, id, subscriber) do
    start(%{kind: :call, nonce: nonce, fun: fun, request_id: id, first: subscriber}, opts)
  end

  @doc "Starts the stream of a session's GET, with `subscriber` attached: the session's notifications."
  @spec start_session(map(), String.t(), subscriber()) :: {:ok, pid(), String.t()}
  def start_session(opts, nonce, subscriber),
    do: start(%{kind: :session, nonce: nonce, first: subscriber}, opts)

  defp start(init, opts) do
    sid = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    state =
      Map.merge(init, %{
        sid: sid,
        server: opts.server,
        events: opts.sse_buffer[:events],
        age: opts.sse_buffer[:age],
        keepalive: opts.keepalive
      })

    {:ok, pid} = DynamicSupervisor.start_child(Streams.Owners, {__MODULE__, state})
    {:ok, pid, sid}
  end

  @doc "The stream the calling handler runs in (inside `start_call/4`'s `fun`)."
  @spec owner() :: pid() | nil
  def owner, do: Process.get(:sake_resumable_owner)

  @doc false
  def child_spec(state),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [state]}, restart: :temporary}

  @doc false
  def start_link(state), do: GenServer.start_link(__MODULE__, state)

  # ---- attaching

  @doc """
  Attaches `subscriber` to the stream `sid` of the session `nonce`, on
  this node: it gets every event after `after_n`, then the live ones.
  `:error` when this node has no such stream (or it is another session's),
  `:evicted` when the buffer no longer has the events after `after_n` (or
  the stream never sent that event).
  """
  @spec attach(String.t(), String.t(), non_neg_integer(), subscriber()) ::
          :ok | :error | :evicted
  def attach(sid, nonce, after_n, subscriber) do
    case Registry.lookup(@registry, {:sake_sse, sid}) do
      [{pid, ^nonce} | _] -> GenServer.call(pid, {:attach, after_n, subscriber})
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  @doc "Detaches `subscriber` from the stream `sid`, on this node."
  @spec detach(String.t(), subscriber()) :: :ok
  def detach(sid, subscriber) do
    case Registry.lookup(@registry, {:sake_sse, sid}) do
      [{pid, _} | _] -> send(pid, {:sake_detach, subscriber})
      [] -> :ok
    end

    :ok
  end

  @doc "The stream ID and number of an event ID; `:error` for one Sake did not give."
  @spec parse_id(String.t()) :: {:ok, String.t(), non_neg_integer()} | :error
  def parse_id(id) do
    with [sid, n] <- String.split(id, ".", parts: 2),
         true <- sid != "",
         {n, ""} when n >= 0 <- Integer.parse(n) do
      {:ok, sid, n}
    else
      _ -> :error
    end
  end

  # ---- the process

  @impl true
  def init(state) do
    {:ok, _} = Registry.register(@registry, {:sake_sse, state.sid}, state.nonce)

    state =
      Map.merge(state, %{
        buffer: :queue.new(),
        next: 1,
        dropped: 0,
        subscriber: nil,
        monitor: nil,
        done: false,
        idle: nil,
        task: nil,
        subscribed: %{}
      })
      |> put_subscriber(state.first)

    state =
      case state.kind do
        :call ->
          me = self()

          task =
            Task.async(fn ->
              Process.put(:sake_resumable_owner, me)
              state.fun.()
            end)

          %{state | task: task}

        :session ->
          :ok = Streams.register_legacy(state.server, state.nonce)
          state
      end

    {:ok, state}
  end

  @impl true
  # An ID from before events the buffer dropped is refused: the client
  # would miss them.
  def handle_call({:attach, after_n, _subscriber}, _from, state)
      when after_n < state.dropped or after_n >= state.next,
      do: {:reply, :evicted, state}

  def handle_call({:attach, after_n, subscriber}, _from, state) do
    state = state |> drop_subscriber() |> expire()

    for {n, message, _at} <- :queue.to_list(state.buffer),
        n > after_n,
        do: deliver(subscriber, state.sid, {:event, n, message})

    state = put_subscriber(state, subscriber)

    if state.done do
      deliver(subscriber, state.sid, :close)
      {:stop, :normal, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  # The handler's messages (its transport is this process).
  def handle_info({:sake_progress, token, current, total, message}, state),
    do: {:noreply, push(state, Sake.Plug.Stream.progress(token, current, total, message))}

  def handle_info({:sake_log, level, data}, state),
    do: {:noreply, push(state, Sake.Plug.Stream.log(level, data))}

  def handle_info({:sake_request, _from, request_id, method, params}, state),
    do: {:noreply, push(state, JSONRPC.request(request_id, method, params))}

  # The 2025-11-25 polling pattern: the handler asks for the connection
  # to be closed; the call goes on, and the client resumes with GET.
  def handle_info(:sake_close_stream, state) do
    if state.subscriber, do: deliver(state.subscriber, state.sid, :close)
    {:noreply, state |> drop_subscriber() |> idle()}
  end

  def handle_info({ref, outcome}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(state, outcome)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state),
    do: finish(state, {:error, Sake.Plug.Stream.failure(:exit, reason, [])})

  # A session's notifications.
  def handle_info({:sake_subscribe, uri}, state),
    do: {:noreply, %{state | subscribed: Map.put(state.subscribed, uri, true)}}

  def handle_info({:sake_unsubscribe, uri}, state),
    do: {:noreply, %{state | subscribed: Map.delete(state.subscribed, uri)}}

  def handle_info({:sake_notify, event}, state) do
    case Sake.Plug.Stream.legacy_notification(event, state.subscribed) do
      nil -> {:noreply, state}
      message -> {:noreply, push(state, message)}
    end
  end

  # The attached connection.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:noreply, state |> drop_subscriber() |> idle()}

  def handle_info({:sake_detach, subscriber}, %{subscriber: subscriber} = state),
    do: {:noreply, state |> drop_subscriber() |> idle()}

  def handle_info({:sake_detach, _other}, state), do: {:noreply, state}

  # No connection for the buffer's age: the stream is given up.
  def handle_info({:sake_idle, ref}, %{idle: ref, subscriber: nil} = state) do
    if state.kind == :call and not state.done do
      # The call goes on: only its delivery is given up. Its outcome, if
      # the client asked for it some other way, is not this stream's.
      Logger.debug("resumable stream #{state.sid}: no connection for #{state.age} ms; dropped")
    end

    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{task: %Task{} = task, done: false}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp finish(state, outcome) do
    outcome = Sake.Trace.outcome(outcome)

    state =
      push(%{state | done: true}, Sake.Plug.Stream.response(state.request_id, outcome), true)

    if state.subscriber do
      deliver(state.subscriber, state.sid, :close)
      {:stop, :normal, state}
    else
      {:noreply, idle(state)}
    end
  end

  # ---- the buffer

  # Each event gets the next number, is kept, and goes to the attached
  # connection. The buffer keeps at most `events` events, none older than
  # `age`; a call's response is never dropped before it was delivered.
  defp push(state, message, final \\ false) do
    n = state.next
    buffer = :queue.in({n, message, if(final, do: :final, else: now())}, state.buffer)
    state = %{state | buffer: buffer, next: n + 1} |> expire() |> bound()
    if state.subscriber, do: deliver(state.subscriber, state.sid, {:event, n, message})
    state
  end

  defp expire(state) do
    oldest = now() - state.age

    {kept, gone} =
      state.buffer
      |> :queue.to_list()
      |> Enum.split_with(fn {_n, _m, at} -> at == :final or at >= oldest end)

    dropped(%{state | buffer: :queue.from_list(kept)}, gone)
  end

  defp dropped(state, gone),
    do: %{state | dropped: Enum.reduce(gone, state.dropped, fn {n, _, _}, acc -> max(n, acc) end)}

  defp bound(state) do
    if :queue.len(state.buffer) > state.events do
      case :queue.out(state.buffer) do
        {{:value, {_n, _m, :final} = final}, rest} ->
          {gone, rest} = drop_one(rest)
          dropped(%{state | buffer: :queue.in_r(final, rest)}, gone)

        {{:value, gone}, rest} ->
          dropped(%{state | buffer: rest}, [gone])
      end
      |> bound()
    else
      state
    end
  end

  defp drop_one(queue) do
    case :queue.out(queue) do
      {{:value, gone}, rest} -> {[gone], rest}
      {:empty, rest} -> {[], rest}
    end
  end

  # ---- the subscriber

  defp put_subscriber(state, {:pid, pid} = subscriber),
    do: %{state | subscriber: subscriber, monitor: Process.monitor(pid), idle: nil}

  defp put_subscriber(state, subscriber), do: %{state | subscriber: subscriber, idle: nil}

  defp drop_subscriber(%{monitor: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | subscriber: nil, monitor: nil}
  end

  defp drop_subscriber(state), do: %{state | subscriber: nil}

  # With no connection attached, the stream waits for one for the buffer's
  # age, then ends.
  defp idle(%{subscriber: nil} = state) do
    ref = make_ref()
    Process.send_after(self(), {:sake_idle, ref}, state.age)
    %{state | idle: ref}
  end

  defp idle(state), do: state

  defp deliver({:pid, pid}, sid, message), do: send(pid, {:sake_sse, sid, message})

  defp deliver({:topic, topic}, sid, message) do
    case :persistent_term.get({Streams, :pubsub}, nil) do
      nil -> :ok
      pubsub -> Streams.publish(pubsub, topic, {:sake_sse, sid, message})
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
