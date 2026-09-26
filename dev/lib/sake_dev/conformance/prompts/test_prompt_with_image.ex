defmodule SakeDev.Conformance.Prompts.TestPromptWithImage do
  @moduledoc false
  use Sake.Prompt, name: "test_prompt_with_image", description: "A prompt with image content"

  alias SakeDev.Conformance.Fixtures

  @impl true
  def get(%{}, _ctx) do
    {:ok,
     [
       user: Sake.Content.image(Fixtures.png(), "image/png"),
       user: "Please analyze the image above."
     ]}
  end
end
