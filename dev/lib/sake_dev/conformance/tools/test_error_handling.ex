defmodule SakeDev.Conformance.Tools.TestErrorHandling do
  @moduledoc false
  use Sake.Tool, name: "test_error_handling", description: "Always returns a tool error"

  @impl true
  def execute(%{}, _ctx), do: {:error, "This tool intentionally returns an error for testing"}
end
