defmodule Sake.Plug.StreamsRelayTest do
  # A legacy session's subscriptions and answers reach its GET stream and
  # its waiting handler on whichever node holds them (issue #43). The
  # other node is played by publishing on the PubSub as it would, under
  # another node's name, and by watching what this node publishes.
  use ExUnit.Case, async: false

  alias Sake.Plug.Streams

  @other :other@node
  @server SakeDev.Server

  setup do
    pubsub = :"sake_relay_test_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    start_supervised!({Streams.Relay, pubsub})
    on_exit(fn -> :persistent_term.erase({Streams, :pubsub}) end)

    # What this node publishes, as another node's relay would get it: the
    # relay publishes with `broadcast_from/4`, which skips the publisher,
    # here the test process itself.
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

  defp from_other_node(pubsub, message),
    do: Phoenix.PubSub.broadcast(pubsub, Streams.topic(), message)

  test "an answer posted to another node reaches the handler waiting here", %{pubsub: pubsub} do
    :ok = Streams.register_request("sake-q1")
    from_other_node(pubsub, {:sake_response, @other, "sake-q1", {:ok, %{"action" => "accept"}}})
    assert_receive {:sake_response, "sake-q1", {:ok, %{"action" => "accept"}}}
    Streams.unregister_request("sake-q1")
  end

  test "an answer no handler here waits for goes to the other nodes" do
    me = node()
    assert :ok = Streams.deliver_response("sake-q2", {:ok, %{}})
    assert_receive {:published, {:sake_response, ^me, "sake-q2", {:ok, %{}}}}
  end

  test "an answer a handler here waits for stays here" do
    :ok = Streams.register_request("sake-q3")
    assert :ok = Streams.deliver_response("sake-q3", {:ok, %{}})
    assert_receive {:sake_response, "sake-q3", {:ok, %{}}}
    refute_receive {:published, {:sake_response, _node, "sake-q3", _}}
    Streams.unregister_request("sake-q3")
  end

  test "a subscription made on another node reaches the session's GET stream here", %{
    pubsub: pubsub
  } do
    :ok = Streams.register_legacy(@server, "nonce-1")

    from_other_node(
      pubsub,
      {:sake_session, @other, @server, "nonce-1", {:sake_subscribe, "issue://1"}}
    )

    assert_receive {:sake_subscribe, "issue://1"}

    from_other_node(
      pubsub,
      {:sake_session, @other, @server, "nonce-1", {:sake_unsubscribe, "issue://1"}}
    )

    assert_receive {:sake_unsubscribe, "issue://1"}

    # Another session's is not.
    from_other_node(
      pubsub,
      {:sake_session, @other, @server, "nonce-2", {:sake_subscribe, "x://"}}
    )

    refute_receive {:sake_subscribe, "x://"}
  end

  test "a subscription made here goes to the other nodes too" do
    me = node()
    Streams.session_subscribe(@server, "nonce-3", "issue://2")

    assert_receive {:published,
                    {:sake_session, ^me, @server, "nonce-3", {:sake_subscribe, "issue://2"}}}
  end

  test "this node's own relayed messages are not delivered twice", %{pubsub: pubsub} do
    :ok = Streams.register_request("sake-q4")
    from_other_node(pubsub, {:sake_response, node(), "sake-q4", {:ok, %{}}})
    refute_receive {:sake_response, "sake-q4", _}
    Streams.unregister_request("sake-q4")
  end
end
