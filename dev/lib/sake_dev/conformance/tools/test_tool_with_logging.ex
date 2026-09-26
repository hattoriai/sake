defmodule SakeDev.Conformance.Tools.TestToolWithLogging do
  @moduledoc false
  # `stream: true` opens the SSE channel this fixture needs to deliver its
  # log notifications, even though the caller sends no progress token.
  use Sake.Tool,
    name: "test_tool_with_logging",
    description: "Sends log messages while it runs",
    stream: true

  @impl true
  def execute(%{}, ctx) do
    Sake.Progress.log(ctx, :info, "Tool execution started")
    Process.sleep(50)
    Sake.Progress.log(ctx, :info, "Tool processing data")
    Process.sleep(50)
    Sake.Progress.log(ctx, :info, "Tool execution completed")
    {:ok, "Done."}
  end
end
