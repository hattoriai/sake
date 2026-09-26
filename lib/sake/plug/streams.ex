defmodule Sake.Plug.Streams do
  @moduledoc """
  The registry of open streams on this node: `subscriptions/listen`
  streams, legacy GET streams, and handlers waiting for a legacy
  elicitation answer. Started by the `Sake` supervisor. With a `pubsub:`
  option (a `Phoenix.PubSub` name) notifications reach every node.
  """

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
  def register_listen(server, subscription_id, filter),
    do: register({server, :listen}, {subscription_id, filter})

  @doc false
  # A listen stream that has sent its final result leaves the registry.
  def unregister_listen(server) do
    if Process.whereis(@registry), do: Registry.unregister(@registry, {server, :listen})
    :ok
  end

  @doc false
  # Every listen stream on this node, of any server.
  def listen_pids do
    if Process.whereis(@registry),
      do: Registry.select(@registry, [{{{:_, :listen}, :"$1", :_}, [], [:"$1"]}]),
      else: []
  end

  @doc "Registers the calling process as a legacy GET stream for the session (by its nonce)."
  def register_legacy(server, session_nonce),
    do: register({server, :legacy, session_nonce}, nil)

  @doc "Registers the calling process as waiting for the client's answer to request `id`."
  def register_elicit(id), do: register({:elicit, id}, nil)

  defp register(key, value) do
    ensure_started!()
    {:ok, _} = Registry.register(@registry, key, value)
    :ok
  end

  @doc "Sends `{:sake_notify, event}` to the streams of `server` on every node."
  @spec broadcast(module(), {:list_changed, atom()} | {:resource_updated, String.t()}) :: :ok
  def broadcast(server, event) do
    local(server, event)

    case :persistent_term.get({__MODULE__, :pubsub}, nil) do
      nil ->
        :ok

      pubsub ->
        relay_broadcast(pubsub, {:sake_broadcast, node(), server, event})
    end
  end

  # Compiled only when the host has Phoenix.PubSub: a host without it never
  # sets a pubsub, and must not see a warning for a module it does not have.
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
    end

    :ok
  end

  defp notify_listeners(server, event) do
    Registry.dispatch(@registry, {server, :listen}, &send_each(&1, event))
  end

  defp notify_legacy_streams(server, event) do
    @registry
    |> Registry.select([{{{server, :legacy, :_}, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(&send(&1, {:sake_notify, event}))
  end

  defp send_each(entries, event),
    do: for({pid, _} <- entries, do: send(pid, {:sake_notify, event}))

  @doc "Routes a legacy client's JSON-RPC response to the handler waiting for it."
  @spec deliver_response(term(), {:ok, map()} | {:error, map()}) :: :ok | :error
  def deliver_response(id, response) do
    ensure_started!()

    case Registry.lookup(@registry, {:elicit, id}) do
      [{pid, _} | _] ->
        send(pid, {:sake_elicit_response, id, response})
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

  defp send_session(server, session_nonce, message) do
    ensure_started!()

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
    end
  end
end
