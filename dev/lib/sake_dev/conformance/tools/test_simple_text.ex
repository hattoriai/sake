defmodule SakeDev.Conformance.Tools.TestSimpleText do
  @moduledoc false
  # A conformance fixture: see conformance/expected-failures.yaml and
  # guides/protocol_versions.md for what this server exists to satisfy.
  use Sake.Tool, name: "test_simple_text", description: "Returns simple text content"

  @impl true
  def execute(%{}, _ctx), do: {:ok, "This is a simple text response for testing."}
end
