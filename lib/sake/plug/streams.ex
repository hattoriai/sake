defmodule Sake.Plug.Streams do
  @moduledoc """
  The registry of open streams on this node: `subscriptions/listen`
  streams, legacy GET streams, and handlers waiting for a legacy
  elicitation answer. Started by the `Sake` supervisor. With a `pubsub:`
  option (a `Phoenix.PubSub` name) notifications reach every node.
  """

  @registry __MODULE__
  @topic "sake:streams"

  def child_spec(opts) do
    children = [{Registry, keys: :duplicate, name: @registry}] ++ relay(opts[:pubsub])

    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_one, name: __MODULE__.Supervisor]]}
    }
  end

  defp relay(nil), do: []
  defp relay(pubsub), do: [{__MODULE__.Relay, pubsub}]

  @doc "Registers the calling process as a modern listen stream."
  def register_listen(server, subscription_id, filter),
    do: register({server, :listen}, {subscription_id, filter})

  @doc "Registers the calling process as a legacy GET stream for the session."
  def register_legacy(server, session_id),
    do: register({server, :legacy, :erlang.phash2(session_id)}, nil)

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
        if Code.ensure_loaded?(Phoenix.PubSub) do
          Phoenix.PubSub.broadcast_from(
            pubsub,
            self(),
            @topic,
            {:sake_broadcast, node(), server, event}
          )
        end

        :ok
    end
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
  def session_subscribe(server, session_id, uri),
    do: send_session(server, session_id, {:sake_subscribe, uri})

  @doc false
  def session_unsubscribe(server, session_id, uri),
    do: send_session(server, session_id, {:sake_unsubscribe, uri})

  defp send_session(server, session_id, message) do
    ensure_started!()

    Registry.dispatch(@registry, {server, :legacy, :erlang.phash2(session_id)}, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end

  defp ensure_started! do
    Process.whereis(@registry) ||
      raise "Sake.Plug.Streams is not running: add {Sake, ...} to your supervision tree"
  end

  if Code.ensure_loaded?(Phoenix.PubSub) do
    defmodule Relay do
      @moduledoc false
      use GenServer

      def start_link(pubsub), do: GenServer.start_link(__MODULE__, pubsub, name: __MODULE__)

      @impl true
      def init(pubsub) do
        :persistent_term.put({Sake.Plug.Streams, :pubsub}, pubsub)
        :ok = Phoenix.PubSub.subscribe(pubsub, "sake:streams")
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
