defmodule SakeDev.Conformance.Tools.TestMultipleContentTypes do
  @moduledoc false
  use Sake.Tool, name: "test_multiple_content_types", description: "Returns several content types"

  alias SakeDev.Conformance.Fixtures

  @impl true
  def execute(%{}, _ctx) do
    {:ok,
     [
       Sake.Content.text("Multiple content types test:"),
       Sake.Content.image(Fixtures.png(), "image/png"),
       Sake.Content.resource(
         "test://mixed-content-resource",
         JSON.encode!(%{"test" => "data", "value" => 123}),
         mime_type: "application/json"
       )
     ]}
  end
end
