defmodule Sake.ClusterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sake.Auth.Config
  alias Sake.Cluster

  @ets_auth %Config{store: {Sake.Auth.Store.ETS, []}}
  @ecto_auth %Config{store: {Sake.Auth.Store.Ecto, repo: SakeTest.Repo}}
  @ecto [store: {Sake.Tasks.Store.Ecto, repo: SakeTest.Repo}]

  defp whats(opts, auth \\ nil, external \\ %{}),
    do: opts |> Cluster.local_state(auth, external) |> Enum.map(&elem(&1, 0))

  describe "local_state/3" do
    test "the defaults keep everything on the node" do
      assert whats([], @ets_auth) == [
               "the authorization server's store is Sake.Auth.Store.ETS",
               "the task store is Sake.Tasks.Store.ETS",
               "single-use JWTs are remembered on this node only",
               "notifications reach this node's streams only"
             ]
    end

    test "shared stores and a pubsub keep nothing on the node" do
      assert whats([tasks: @ecto, pubsub: SakeTest.PubSub], @ecto_auth) == []
    end

    test "what is turned off is not counted" do
      assert whats(tasks: false, streams: false) == []
    end

    test "the replay table follows the replay store, else the auth store" do
      replay = "single-use JWTs are remembered on this node only"
      shared = [tasks: false, streams: false]

      assert whats(shared, @ets_auth) == [
               "the authorization server's store is Sake.Auth.Store.ETS",
               replay
             ]

      assert whats(shared ++ [replay: {Sake.Auth.Store.Ecto, repo: SakeTest.Repo}], @ets_auth) ==
               ["the authorization server's store is Sake.Auth.Store.ETS"]

      # Only external authorization servers: a table on each node, unless
      # a replay store is given.
      external = %{"https://idp.example" => :issuer}
      assert whats(shared, nil, external) == [replay]

      assert whats(shared ++ [replay: {Sake.Auth.Store.Ecto, repo: SakeTest.Repo}], nil, external) ==
               []
    end
  end

  describe "the warning" do
    test "nothing is logged while the node is alone" do
      log =
        capture_log(fn ->
          pid = start_supervised!({Cluster, Cluster.local_state([], @ets_auth, %{})})
          _ = :sys.get_state(pid)
        end)

      refute log =~ "Sake: this node"
    end

    test "is logged once, when a node connects, naming each piece of local state" do
      log =
        capture_log(fn ->
          pid = start_supervised!({Cluster, Cluster.local_state([tasks: @ecto], @ets_auth, %{})})
          ref = Process.monitor(pid)
          send(pid, {:nodeup, :other@host})
          send(pid, {:nodeup, :third@host})
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        end)

      assert [_, _] = String.split(log, "Sake: this node")
      assert log =~ "connected to other@host"
      assert log =~ "auth: [store: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}]"
      assert log =~ "pubsub: MyApp.PubSub"
      refute log =~ "tasks: [store:"
    end
  end
end
