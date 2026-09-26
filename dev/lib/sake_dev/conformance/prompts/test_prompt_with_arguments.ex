defmodule SakeDev.Conformance.Prompts.TestPromptWithArguments do
  @moduledoc false
  use Sake.Prompt,
    name: "test_prompt_with_arguments",
    description: "A prompt parameterized by two arguments"

  arg :arg1, :string, required: true
  arg :arg2, :string, required: true

  @impl true
  def get(%{arg1: arg1, arg2: arg2}, _ctx),
    do: {:ok, [user: "Prompt with arguments: arg1='#{arg1}', arg2='#{arg2}'"]}
end
