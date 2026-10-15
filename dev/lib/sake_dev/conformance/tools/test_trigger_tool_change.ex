defmodule SakeDev.Conformance.Tools.TestTriggerToolChange do
  @moduledoc false
  # server-stateless: stands in for a change to the tool list, so the
  # suite can watch `notifications/tools/list_changed` arrive on an open
  # `subscriptions/listen` stream.
  use Sake.Tool,
    name: "test_trigger_tool_change",
    description: "Announces a change to the tool list"

  @impl true
  def execute(%{}, ctx) do
    Sake.Server.notify_list_changed(ctx.server, :tools)
    {:ok, "Tool list change announced."}
  end
end
