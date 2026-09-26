defmodule SakeDev.Conformance.Tools.TestEmbeddedResource do
  @moduledoc false
  use Sake.Tool, name: "test_embedded_resource", description: "Returns an embedded resource"

  @impl true
  def execute(%{}, _ctx) do
    {:ok,
     [
       Sake.Content.resource(
         "test://embedded-resource",
         "This is an embedded resource content.",
         mime_type: "text/plain"
       )
     ]}
  end
end
