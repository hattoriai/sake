defmodule SakeDev.Conformance.Tools.TestReconnection do
  @moduledoc false
  # server-sse-polling (2025-11-25): the tool closes its stream's
  # connection before it answers (`Sake.Progress.close_stream/1`), so the
  # client must resume with GET and `Last-Event-ID` to get the response.
  # `stream: true` gives the call an SSE stream to close.
  use Sake.Tool,
    name: "test_reconnection",
    description: "Closes its SSE stream mid-call to test reconnection",
    stream: true

  @impl true
  def execute(%{}, ctx) do
    Sake.Progress.close_stream(ctx)
    Process.sleep(100)
    {:ok, "Reconnection test completed successfully"}
  end
end
