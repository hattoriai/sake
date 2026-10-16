defmodule Sake.Client.ListenTest do
  use ExUnit.Case, async: false

  alias Sake.Client
  alias SakeTest.{HTTP, StdioScript, Upstream}

  @filter %{
    "toolsListChanged" => true,
    "resourceSubscriptions" => ["issue://1"]
  }

  for transport <- [:http, :stdio], era <- [:modern, :legacy] do
    test "list changes and subscribed resource updates (#{transport}, #{era})" do
      target =
        case unquote(transport) do
          :http -> HTTP.start(Upstream.Router) <> "/mcp"
          :stdio -> StdioScript.script("upstream")
        end

      assert {:ok, session} = Client.connect(target, era: unquote(era), stderr: :ignore)
      test = self()

      listener =
        spawn_link(fn ->
          result = Client.listen(session, @filter, &send(test, {:heard, &1, &2}))
          send(test, {:listen_ended, result})
        end)

      # The stream is open once the server acknowledged it (modern), or a
      # moment after the subscription was made (legacy, which says
      # nothing); a call that announces changes is heard on it.
      if unquote(era) == :modern,
        do: assert_receive({:heard, "notifications/subscriptions/acknowledged", _}, 2_000),
        else: Process.sleep(300)

      assert {:ok, %{text: "announced"}, session} = Client.call_tool(session, "changes", %{})

      assert_receive {:heard, "notifications/tools/list_changed", _}, 2_000

      assert_receive {:heard, "notifications/resources/updated", %{"uri" => "issue://1"}},
                     2_000

      refute_received {:listen_ended, _}
      Process.unlink(listener)
      Process.exit(listener, :kill)
      assert :ok = Client.close(session)
    end
  end
end
