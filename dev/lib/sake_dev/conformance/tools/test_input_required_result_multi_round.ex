defmodule SakeDev.Conformance.Tools.TestInputRequiredResultMultiRound do
  @moduledoc false
  # SEP-2322: two questions in two rounds. The second round's request state
  # carries the first answer, so it differs from the first round's.
  use Sake.Tool,
    name: "test_input_required_result_multi_round",
    description: "Asks two questions, one round each"

  @impl true
  def execute(%{}, ctx) do
    with {:ok, %{"name" => name}} <-
           Sake.Elicit.form(ctx, :step1, "Step 1: What is your name?", schema("name")),
         {:ok, %{"color" => color}} <-
           Sake.Elicit.form(ctx, :step2, "Step 2: What is your favorite color?", schema("color")) do
      {:ok, "#{name} likes #{color}."}
    else
      {:error, :unsupported} -> {:error, "This tool needs a client that supports elicitation."}
      _ -> {:error, "Both questions need an answer."}
    end
  end

  defp schema(field) do
    %{
      "type" => "object",
      "properties" => %{field => %{"type" => "string"}},
      "required" => [field]
    }
  end
end
