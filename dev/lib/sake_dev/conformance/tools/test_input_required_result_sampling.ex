defmodule SakeDev.Conformance.Tools.TestInputRequiredResultSampling do
  @moduledoc false
  use Sake.Tool,
    name: "test_input_required_result_sampling",
    description: "Asks the client's model a question"

  @impl true
  def execute(%{}, ctx) do
    case Sake.Sampling.create_message(
           ctx,
           :capital_question,
           [user: "What is the capital of France?"],
           max_tokens: 100
         ) do
      {:ok, %{text: text}} -> {:ok, text}
      {:error, reason} -> {:error, "Sampling failed: #{inspect(reason)}"}
    end
  end
end
