defmodule SakeDev.Conformance.Tools.TestLoggingTool do
  @moduledoc false
  # server-stateless: a request without a `_meta` log level gets no
  # `notifications/message`, however much the tool logs.
  use Sake.Tool,
    name: "test_logging_tool",
    description: "Logs while it runs",
    stream: true

  @impl true
  def execute(%{}, ctx) do
    Sake.Progress.log(ctx, :info, "Tool execution started")
    Sake.Progress.log(ctx, :info, "Tool execution completed")
    {:ok, "Done."}
  end
end
