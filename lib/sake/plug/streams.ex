defmodule Sake.Plug.Streams do
  @moduledoc """
  The registry of open streams on this node: `subscriptions/listen`
  streams, legacy GET streams, and handlers waiting for a legacy client's
  answer to a server request (elicitation, sampling, roots). Started by
  the `Sake` supervisor. With a `pubsub:` option (a `Phoenix.PubSub`
  name) every node takes part: notifications reach the streams on every
  node, and a legacy session's subscriptions and answers reach its GET
  stream and its waiting handler on whichever node holds them, wherever
  the client's POST landed.

  A stream of a server that mounts others (`Sake.Server.mount/2`) also
  follows their broadcasts, with resource URIs under the mount's prefix.
  """

  alias Sake.Server.Mount

  @registry __MODULE__

  def child_spec(opts) do
    # The shutdown notifier starts after the registry, so it stops before
    # it: open listen streams still get to finish while the registry runs.
    children =
      [{Registry, keys: :duplicate, name: @registry}, __MODULE__.Shutdown] ++
        relay(opts[:pubsub])

    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_one, name: __MODULE__.Supervisor]]}
    }
  end

  @doc false
  def topic, do: "sake:streams"

  defp relay(nil), do: []
  defp relay(pubsub), do: [{__MODULE__.Relay, pubsub}]

  @doc "Registers the calling process as a modern listen stream."
  def register_listen(server, subscription_id, filter) do
    for {server, prefixes} <- Mount.tree(server),
        do: register({server, :listen}, {subscription_id, filter, prefixes})

    :ok
  end

  @doc false
  # A listen stream that has sent its final result leaves the registry.
  def unregister_listen(server) do
    if Process.whereis(@registry) do
      for {server, _prefixes} <- Mount.tree(server),
          do: Registry.unregister(@registry, {server, :listen})
    end

    :ok
  end

  @doc false
  # Every listen stream on this node, of any server.
  def listen_pids do
    if Process.whereis(@registry),
      do:
        @registry |> Registry.select([{{{:_, :listen}, :"$1", :_}, [], [:"$1"]}]) |> Enum.uniq(),
      else: []
  end

  @doc """
  Registers the calling process as a legacy GET stream for the session (by
  its nonce). The session's subscriptions reach it under the server's own
  key only.
  """
  def register_legacy(server, session_nonce) do
    for {server, prefixes} <- Mount.tree(server),
        do: register({server, :legacy, session_nonce}, prefixes)

    :ok
  end

  @doc false
  # Registers the calling process as a test's listener (`Sake.Test`): it
  # gets `{tag, server, event}` for the broadcasts of `server` made by
  # `owner` or by a process `owner` started (its `$callers`), so tests
  # running concurrently do not see each other's. An `owner` of `:any`
  # gets every broadcast of the server.
  def register_test(server, owner, tag) do
    for {server, prefixes} <- Mount.tree(server),
        do: register({server, :test, owner}, {tag, prefixes})

    :ok
  end

  @doc false
  def unregister_test(server, owner, tag) do
    if Process.whereis(@registry) do
      for {server, _prefixes} <- Mount.tree(server),
          do: Registry.unregister_match(@registry, {server, :test, owner}, {tag, :_})
    end

    :ok
  end

  @doc "Registers the calling process as waiting for the client's answer to request `id`."
  def register_request(id), do: register({:request, id}, nil)

  @doc false
  # The answer arrived (or the wait timed out).
  def unregister_request(id) do
    if Process.whereis(@registry), do: Registry.unregister(@registry, {:request, id})
    :ok
  end

  defp register(key, value) do
    ensure_started!()
    {:ok, _} = Registry.register(@registry, key, value)
    :ok
  end

  @doc "Sends `{:sake_notify, event}` to the streams of `server` on every node."
  @spec broadcast(
          module(),
          {:list_changed, atom()}
          | {:resource_updated, String.t()}
          | {:task, map()}
          | {:extension, String.t(), String.t(), map()}
        ) :: :ok
  def broadcast(server, event) do
    local(server, event)
    _ = to_other_nodes({:sake_broadcast, node(), server, event})
    :ok
  end

  # Sends `message` to the relay of every other node; `:none` without a
  # pubsub.
  defp to_other_nodes(message) do
    case :persistent_term.get({__MODULE__, :pubsub}, nil) do
      nil -> :none
      pubsub -> relay_broadcast(pubsub, message)
    end
  end

  # Compiled only when the host has Phoenix.PubSub: a host without it never
  # sets a pubsub, and must not see a warning for a module it does not have.
  # Without it this clause never runs; it answers as the real one would.
  if Code.ensure_loaded?(Phoenix.PubSub) do
    defp relay_broadcast(pubsub, message) do
      Phoenix.PubSub.broadcast_from(pubsub, self(), topic(), message)
      :ok
    end
  else
    defp relay_broadcast(_pubsub, _message), do: :ok
  end

  @doc false
  def local(server, event) do
    if Process.whereis(@registry) do
      notify_listeners(server, event)
      notify_legacy_streams(server, event)
      notify_tests(server, event)
    end

    :ok
  end

  defp notify_listeners(server, event) do
    Registry.dispatch(@registry, {server, :listen}, &send_each(&1, event))
  end

  defp notify_legacy_streams(server, event) do
    @registry
    |> Registry.select([{{{server, :legacy, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {pid, prefixes} ->
      send_translated(pid, event, prefixes, &{:sake_notify, &1})
    end)
  end

  defp notify_tests(server, event) do
    for owner <- [:any, self() | Process.get(:"$callers", [])] do
      Registry.dispatch(@registry, {server, :test, owner}, &send_tagged(&1, server, event))
    end
  end

  defp send_tagged(entries, server, event) do
    for {pid, {tag, prefixes}} <- entries,
        do: send_translated(pid, event, prefixes, &{tag, server, &1})
  end

  defp send_each(entries, event) do
    for {pid, {_id, _filter, prefixes}} <- entries,
        do: send_translated(pid, event, prefixes, &{:sake_notify, &1})
  end

  # A mounted server's broadcast, as the stream of the server that mounts
  # it tells its client; one that cannot be renamed is not told.
  defp send_translated(pid, event, prefixes, message) do
    case Mount.translate(event, prefixes) do
      nil -> :ok
      event -> send(pid, message.(event))
    end
  end

  @doc """
  Routes a legacy client's JSON-RPC response to the handler waiting for
  it: on this node, else (with a pubsub) on whichever node it waits on.
  `:error` when no node can have it.
  """
  @spec deliver_response(term(), {:ok, map()} | {:error, map()}) :: :ok | :error
  def deliver_response(id, response) do
    ensure_started!()

    case deliver_local(id, response) do
      :ok ->
        :ok

      :error ->
        if to_other_nodes({:sake_response, node(), id, response}) == :ok,
          do: :ok,
          else: :error
    end
  end

  @doc false
  def deliver_local(id, response) do
    case Registry.lookup(@registry, {:request, id}) do
      [{pid, _} | _] ->
        send(pid, {:sake_response, id, response})
        :ok

      [] ->
        :error
    end
  end

  @doc false
  def session_subscribe(server, session_nonce, uri),
    do: send_session(server, session_nonce, {:sake_subscribe, uri})

  @doc false
  def session_unsubscribe(server, session_nonce, uri),
    do: send_session(server, session_nonce, {:sake_unsubscribe, uri})

  # The session's GET stream may be open on another node: the message goes
  # there too.
  defp send_session(server, session_nonce, message) do
    ensure_started!()
    session_local(server, session_nonce, message)
    _ = to_other_nodes({:sake_session, node(), server, session_nonce, message})
    :ok
  end

  @doc false
  def session_local(server, session_nonce, message) do
    Registry.dispatch(@registry, {server, :legacy, session_nonce}, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end

  defp ensure_started! do
    Process.whereis(@registry) ||
      raise "Sake.Plug.Streams is not running: add {Sake, ...} to your supervision tree"
  end

  defmodule Shutdown do
    @moduledoc false
    # When the node shuts down (or the stream supervisor stops), every open
    # `subscriptions/listen` stream sends its final result, so a client
    # sees the subscription end cleanly instead of a dropped connection.
    use GenServer

    @grace 2_000

    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @impl true
    def init(nil) do
      Process.flag(:trap_exit, true)
      {:ok, nil}
    end

    @impl true
    def terminate(_reason, _state) do
      pids = Sake.Plug.Streams.listen_pids()
      Enum.each(pids, &send(&1, :sake_shutdown))
      wait(pids, System.monotonic_time(:millisecond) + @grace)
    end

    # Waits until the streams have left the registry (each does after its
    # final write), or the grace period ends.
    defp wait([], _deadline), do: :ok

    defp wait(pids, deadline) do
      open = Sake.Plug.Streams.listen_pids()
      pids = Enum.filter(pids, &(&1 in open))

      if pids != [] and System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        wait(pids, deadline)
      else
        :ok
      end
    end
  end

  if Code.ensure_loaded?(Phoenix.PubSub) do
    defmodule Relay do
      @moduledoc false
      use GenServer

      def start_link(pubsub), do: GenServer.start_link(__MODULE__, pubsub, name: __MODULE__)

      @impl true
      def init(pubsub) do
        :persistent_term.put({Sake.Plug.Streams, :pubsub}, pubsub)
        :ok = Phoenix.PubSub.subscribe(pubsub, Sake.Plug.Streams.topic())
        {:ok, pubsub}
      end

      @impl true
      def handle_info({:sake_broadcast, from_node, server, event}, pubsub) do
        if from_node != node(), do: Sake.Plug.Streams.local(server, event)
        {:noreply, pubsub}
      end

      def handle_info({:sake_response, from_node, id, response}, pubsub) do
        if from_node != node(), do: Sake.Plug.Streams.deliver_local(id, response)
        {:noreply, pubsub}
      end

      def handle_info({:sake_session, from_node, server, session_nonce, message}, pubsub) do
        if from_node != node(),
          do: Sake.Plug.Streams.session_local(server, session_nonce, message)

        {:noreply, pubsub}
      end
    end
  end
end
