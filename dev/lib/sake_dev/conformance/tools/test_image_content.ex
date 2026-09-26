defmodule SakeDev.Conformance.Tools.TestImageContent do
  @moduledoc false
  use Sake.Tool, name: "test_image_content", description: "Returns image content"

  alias SakeDev.Conformance.Fixtures

  @impl true
  def execute(%{}, _ctx),
    do: {:ok, [Sake.Content.image(Fixtures.png(), "image/png")]}
end
