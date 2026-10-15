defmodule SakeDev.Conformance.Prompts.TestInputRequiredResultPrompt do
  @moduledoc false
  # SEP-2322: an input-required result from `prompts/get`, not a tool call.
  use Sake.Prompt,
    name: "test_input_required_result_prompt",
    description: "Asks for context before it builds the prompt"

  @impl true
  def get(%{}, ctx) do
    schema = %{
      "type" => "object",
      "properties" => %{"context" => %{"type" => "string"}},
      "required" => ["context"]
    }

    case Sake.Elicit.form(ctx, :user_context, "What context should the prompt use?", schema) do
      {:ok, %{"context" => context}} -> {:ok, [user: "Use this context: #{context}"]}
      {:error, :unsupported} -> {:error, "This prompt needs a client that supports elicitation."}
      _ -> {:ok, [user: "Use no particular context."]}
    end
  end
end
