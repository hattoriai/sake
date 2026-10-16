defmodule Sake.Client.Stdio do
  @moduledoc false
  # The process that owns a stdio server's port. It writes the client's
  # messages to the server's standard input, one line each, and hands each
  # line the server writes back to the call waiting for it: a response by
  # its id, a progress notification by its token (the request's own id),
  # any other notification and a legacy server's request to the oldest
  # call in flight. The waiting call answers a request itself, with the
  # session it holds (`on_input`), and runs `on_notification`; this process
  # only answers `ping`.
  #
  # Each request goes to the server under an id of this process's own, and
  # its response comes back under the caller's: callers that share a
  # session, or a caller that reuses an id after giving up on a call, never
  # get each other's responses.
  #
  # The notifications of a `subscriptions/listen` request carry its id (in
  # `_meta`), and go to it. A legacy server's list changes and resource
  # updates belong to no call: they go to the processes that `listen/2`.

  use GenServer
  require Logger

  alias Sake.Client.{Session, Transport}
  alias Sake.JSONRPC

  @line 65_536
  @close_timeout 5_000

  @spec start(String.t(), [String.t()], keyword()) :: {:ok, pid()} | {:error, term()}
  def start(command, args, opts) do
    case executable(command, opts[:cd]) do
      nil ->
        {:error, :enoent}

      path ->
        with {:ok, pid} <- GenServer.start(__MODULE__, {path, args, opts}) do
          # Linked once started, so a failure to start is an error and not
          # an exit: the caller's death still closes the server's input.
          Process.link(pid)
          {:ok, pid}
        end
    end
  end

  defp executable(command, cd) do
    path =
      if String.contains?(command, "/"),
        do: Path.expand(command, cd || File.cwd!()),
        else: System.find_executable(command)

    if path && File.regular?(path), do: path
  end

  @spec post(Session.t(), map(), keyword()) ::
          {:ok, map() | :accepted, Session.t()} | {:error, term()}
  def post(%Session{stdio: pid} = session, %{"id" => id, "method" => _} = message, opts) do
    ref = Process.monitor(pid)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 300_000)

    try do
      if call(pid, {:request, message, self()}) == :ok,
        do: await(session, pid, ref, id, deadline),
        else: {:error, :closed}
    after
      Process.demonitor(ref, [:flush])
    end
  end

  def post(%Session{stdio: pid} = session, message, _opts) do
    case call(pid, {:send, message}) do
      :ok -> {:ok, :accepted, session}
      :closed -> {:error, :closed}
    end
  end

  defp await(session, pid, ref, id, deadline) do
    receive do
      {:sake_stdio, ^id, {:response, message}} ->
        {:ok, message, session}

      {:sake_stdio, ^id, {:notification, method, params}} ->
        Transport.notify(session, method, params)
        await(session, pid, ref, id, deadline)

      {:sake_stdio, ^id, {:request, rid, method, params}} ->
        _ = call(pid, {:send, answer(session, pid, id, rid, method, params)})
        await(session, pid, ref, id, deadline)

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {:error, :closed}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        GenServer.cast(pid, {:cancel, self(), id, "Request timed out"})
        {:error, :timeout}
    end
  end

  # An answering function that throws gives up on the call: the server's
  # question gets an error, the call is cancelled, and the throw carries
  # on (see `Sake.Client.Transport`).
  defp answer(session, pid, id, rid, method, params) do
    Transport.answer(session, rid, method, params)
  catch
    :throw, value ->
      message = JSONRPC.error(rid, JSONRPC.code(:internal), "The call was abandoned")
      _ = call(pid, {:send, message})
      GenServer.cast(pid, {:cancel, self(), id, "The call was abandoned"})
      throw(value)
  end

  @session_notifications [
    "notifications/tools/list_changed",
    "notifications/resources/list_changed",
    "notifications/prompts/list_changed",
    "notifications/resources/updated"
  ]

  @doc "Hands the server's notifications between calls to `fun`, until the server exits."
  @spec listen(pid(), (String.t(), map() -> any())) :: :ok | {:error, :closed}
  def listen(pid, fun) do
    ref = Process.monitor(pid)

    if call(pid, {:listen, self()}) == :ok,
      do: listened(ref, pid, fun),
      else: {:error, :closed}
  end

  defp listened(ref, pid, fun) do
    receive do
      {:sake_stdio_notification, method, params} ->
        fun.(method, params)
        listened(ref, pid, fun)

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    end
  end

  defp call(pid, message) do
    GenServer.call(pid, message, :infinity)
  catch
    :exit, _ -> :closed
  end

  @doc "Closes the server's input, waits for it to exit, and kills it after a timeout."
  @spec close(pid()) :: :ok
  def close(pid) do
    _ = call(pid, :close)
    :ok
  end

  # ---- the port

  @impl true
  def init({path, args, opts}) do
    # A server that exits before it reads its input breaks the pipe, and
    # the port exits with `:epipe`: trapped, that ends this process like
    # any other exit of the server, instead of taking the caller with it.
    Process.flag(:trap_exit, true)

    {path, args} =
      if opts[:stderr] == :ignore,
        do: {"/bin/sh", ["-c", ~s(exec "$0" "$@" 2>/dev/null), path | args]},
        else: {path, args}

    port =
      Port.open(
        {:spawn_executable, path},
        [:binary, :exit_status, :use_stdio, :hide, {:line, @line}, {:args, args}] ++
          env(opts[:env]) ++ cd(opts[:cd])
      )

    # A server that exited at once may have closed its port already; its
    # exit is then waiting in the mailbox, and there is no process to stop.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    {:ok,
     %{
       port: port,
       os_pid: os_pid,
       close_timeout: opts[:close_timeout] || @close_timeout,
       line: [],
       waiters: [],
       listeners: [],
       wire_id: 0
     }}
  end

  defp env(nil), do: []

  defp env(env),
    do: [
      env:
        Enum.map(env, fn {k, v} -> {to_charlist(k), if(v, do: to_charlist(v), else: false)} end)
    ]

  defp cd(nil), do: []
  defp cd(dir), do: [cd: to_charlist(dir)]

  @impl true
  def handle_call({:request, %{"id" => id} = message, from}, _from, state) do
    wire_id = state.wire_id + 1
    write(state, %{message | "id" => wire_id})
    {:reply, :ok, %{state | waiters: state.waiters ++ [{wire_id, id, from}], wire_id: wire_id}}
  end

  def handle_call({:listen, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | listeners: [pid | state.listeners]}}
  end

  def handle_call({:send, message}, _from, state) do
    write(state, message)
    {:reply, :ok, state}
  end

  # The server's standard input closes first, which is the graceful
  # shutdown signal; a server still running after `close_timeout` gets
  # SIGTERM, then SIGKILL.
  def handle_call(:close, _from, state) do
    close_port(state.port)
    deadline = System.monotonic_time(:millisecond) + state.close_timeout

    unless exited?(state.os_pid, deadline) do
      signal(state.os_pid, "TERM")

      unless exited?(state.os_pid, System.monotonic_time(:millisecond) + 1_000),
        do: signal(state.os_pid, "KILL")
    end

    {:stop, :normal, :ok, state}
  end

  # A call that timed out stops waiting; the server is told to stop working
  # on it, as the specification asks of a client that gives up.
  @impl true
  def handle_cast({:cancel, pid, id, reason}, state) do
    case Enum.find(state.waiters, &match?({_wire_id, ^id, ^pid}, &1)) do
      {wire_id, _id, _pid} = waiter ->
        params = %{"requestId" => wire_id, "reason" => reason}
        write(state, JSONRPC.notification("notifications/cancelled", params))
        {:noreply, %{state | waiters: List.delete(state.waiters, waiter)}}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | line: [state.line | chunk]}}

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = IO.iodata_to_binary([state.line | chunk])
    {:noreply, dispatch(line, %{state | line: []})}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.debug("Sake.Client stdio server exited with status #{status}")
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.debug("Sake.Client stdio server's port closed: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | listeners: List.delete(state.listeners, pid)}}

  # Exits are trapped only for the port's sake: the caller's exit still
  # ends this process (and so the server's input) unless it was normal.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch("", state), do: state

  defp dispatch(line, state) do
    with {:ok, json} <- JSON.decode(line),
         parsed when parsed != {:error, :malformed} <- JSONRPC.parse(json) do
      route(parsed, json, state)
    else
      _ ->
        Logger.warning("Sake.Client ignored a line from the stdio server that is not JSON-RPC")
        state
    end
  end

  defp route({kind, wire_id, _}, message, state) when kind in [:response, :error_response] do
    case List.keytake(state.waiters, wire_id, 0) do
      {{^wire_id, id, pid}, waiters} ->
        send(pid, {:sake_stdio, id, {:response, %{message | "id" => id}}})
        %{state | waiters: waiters}

      nil ->
        state
    end
  end

  # A listen stream's notifications carry its id; a progress token is the
  # caller's own id for its request.
  defp route({:notification, method, params}, _message, state) do
    subscription = get_in(params, ["_meta", Sake.Protocol.meta(:subscription_id)])

    cond do
      waiter = subscription && List.keyfind(state.waiters, subscription, 0) ->
        notify_waiter(waiter, method, params)

      method in @session_notifications ->
        Enum.each(state.listeners, &send(&1, {:sake_stdio_notification, method, params}))

      waiter = List.keyfind(state.waiters, params["progressToken"], 1) ->
        notify_waiter(waiter, method, params)

      waiter = List.first(state.waiters) ->
        notify_waiter(waiter, method, params)

      true ->
        :ok
    end

    state
  end

  defp route({:request, rid, "ping", _params}, _message, state) do
    write(state, JSONRPC.result(rid, %{}))
    state
  end

  defp route({:request, rid, method, params}, _message, state) do
    case state.waiters do
      [{_wire_id, id, pid} | _] ->
        send(pid, {:sake_stdio, id, {:request, rid, method, params}})

      [] ->
        write(state, JSONRPC.error(rid, JSONRPC.code(:invalid_request), "No call is waiting"))
    end

    state
  end

  defp route(_parsed, _message, state), do: state

  defp notify_waiter({_wire_id, id, pid}, method, params),
    do: send(pid, {:sake_stdio, id, {:notification, method, params}})

  # A port that already closed has its exit waiting in the mailbox.
  defp write(state, message) do
    Port.command(state.port, [Sake.JSON.encode_to_iodata!(message), ?\n])
  rescue
    ArgumentError -> true
  end

  # A server that exited on its own has taken its port with it.
  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> true
  end

  defp exited?(os_pid, deadline) do
    cond do
      not alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        exited?(os_pid, deadline)
    end
  end

  defp alive?(nil), do: false

  defp alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true))

  defp signal(nil, _name), do: :ok

  defp signal(os_pid, name),
    do: System.cmd("kill", ["-" <> name, to_string(os_pid)], stderr_to_stdout: true)
end
