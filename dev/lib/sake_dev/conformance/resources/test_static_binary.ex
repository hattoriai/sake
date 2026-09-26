defmodule SakeDev.Conformance.Resources.TestStaticBinary do
  @moduledoc false
  use Sake.Resource,
    uri: "test://static-binary",
    name: "test-static-binary",
    mime_type: "image/png"

  alias SakeDev.Conformance.Fixtures

  @impl true
  def read(%{}, _ctx), do: {:ok, {:blob, Fixtures.png(), "image/png"}}
end
