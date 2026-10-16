defmodule Sake.Cluster do
  @moduledoc false
  # Warns, once, when state that Sake keeps on one node meets a cluster:
  # the ETS auth or task store, the replay table without a shared store,
  # or streams without a pubsub. Started by `Sake` only when there is such
  # state; it watches for a node to connect, since a node often joins its
  # cluster after it booted, and stops once it warned. See
  # guides/clustering.md.
  use GenServer, restart: :temporary

  require Logger

  @doc "What runs on this node only, as `{what, remedy}` pairs."
  @spec local_state(keyword(), Sake.Auth.Config.t() | nil, map()) :: [{String.t(), String.t()}]
  def local_state(opts, auth, external) do
    auth_store = auth && elem(auth.store, 0)

    tasks_store =
      case Keyword.get(opts, :tasks, []) do
        false -> nil
        tasks -> tasks |> Keyword.get(:store, {Sake.Tasks.Store.ETS, []}) |> elem(0)
      end

    replay_store =
      case opts[:replay] do
        {module, _} -> module
        nil -> auth_store
      end

    replay? = auth != nil or external != %{}

    [
      {auth_store == Sake.Auth.Store.ETS,
       {"the authorization server's store is Sake.Auth.Store.ETS",
        "auth: [store: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}]"}},
      {tasks_store == Sake.Tasks.Store.ETS,
       {"the task store is Sake.Tasks.Store.ETS",
        "tasks: [store: {Sake.Tasks.Store.Ecto, repo: MyApp.Repo}]"}},
      {replay? and replay_store in [nil, Sake.Auth.Store.ETS],
       {"single-use JWTs are remembered on this node only",
        "replay: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}"}},
      {Keyword.get(opts, :streams, true) and opts[:pubsub] == nil,
       {"notifications reach this node's streams only", "pubsub: MyApp.PubSub"}}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  def start_link(local), do: GenServer.start_link(__MODULE__, local)

  @impl true
  def init(local) do
    :ok = :net_kernel.monitor_nodes(true)

    case Node.list() do
      [] ->
        {:ok, local}

      [node | _] ->
        warn(local, node)
        :ignore
    end
  end

  @impl true
  def handle_info({:nodeup, node}, local) do
    warn(local, node)
    {:stop, :normal, local}
  end

  def handle_info(_message, local), do: {:noreply, local}

  defp warn(local, node) do
    Logger.warning("""
    Sake: this node (#{node()}) is connected to #{node}, but some of Sake's state \
    is kept on each node, so a request that lands on another node does not see it:

    #{Enum.map_join(local, "\n", fn {what, remedy} -> "  * #{what}; set #{remedy}" end)}

    See the "Running on several nodes" guide.\
    """)
  end
end
