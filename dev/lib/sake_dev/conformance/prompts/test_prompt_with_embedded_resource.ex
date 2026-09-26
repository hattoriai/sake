defmodule SakeDev.Conformance.Prompts.TestPromptWithEmbeddedResource do
  @moduledoc false
  use Sake.Prompt,
    name: "test_prompt_with_embedded_resource",
    description: "A prompt that embeds a resource"

  # The wire argument name is exactly the declared name (no camelCase
  # conversion), and the fixture contract this satisfies calls it
  # "resourceUri".
  arg :resourceUri, :string, required: true

  @impl true
  def get(%{resourceUri: uri}, _ctx) do
    {:ok,
     [
       user:
         Sake.Content.resource(uri, "Embedded resource content for testing.",
           mime_type: "text/plain"
         ),
       user: "Please process the embedded resource above."
     ]}
  end
end
