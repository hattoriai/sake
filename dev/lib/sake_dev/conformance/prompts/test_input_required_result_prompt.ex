defmodule SakeDev.Conformance.Prompts.TestInputRequiredResultPrompt do
  @moduledoc false
  use Sake.Prompt,
    name: "test_input_required_result_prompt",
    description: "Asks for the context the prompt should use"

  @impl true
  def get(%{}, ctx) do
    case Sake.Elicit.form(ctx, :user_context, "What context should the prompt use?", %{
           "type" => "object",
           "properties" => %{"context" => %{"type" => "string"}},
           "required" => ["context"]
         }) do
      {:ok, %{"context" => context}} -> {:ok, [user: "Use this context: #{context}"]}
      other -> {:error, "No context: #{inspect(other)}"}
    end
  end
end
