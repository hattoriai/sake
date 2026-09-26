defmodule SakeDev.Conformance.Prompts.TestSimplePrompt do
  @moduledoc false
  use Sake.Prompt, name: "test_simple_prompt", description: "A prompt with no arguments"

  @impl true
  def get(%{}, _ctx), do: {:ok, [user: "This is a simple prompt for testing."]}
end
