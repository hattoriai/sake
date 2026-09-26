defmodule SakeDev.Conformance.Tools.TestToolWithProgress do
  @moduledoc false
  # No `stream: true` needed: a request that carries a progress token opens
  # the SSE channel on its own; `Sake.Progress.report/3` is a no-op when
  # the caller sent none, so the same tool serves both cases.
  use Sake.Tool, name: "test_tool_with_progress", description: "Reports progress while it runs"

  @impl true
  def execute(%{}, ctx) do
    Sake.Progress.report(ctx, 0, 100)
    Process.sleep(50)
    Sake.Progress.report(ctx, 50, 100)
    Process.sleep(50)
    Sake.Progress.report(ctx, 100, 100)
    {:ok, "Done."}
  end
end
