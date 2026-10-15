defmodule SakeDev.Conformance.Tools.TestInputRequiredResultMultiRound do
  @moduledoc false
  use Sake.Tool,
    name: "test_input_required_result_multi_round",
    description: "Asks for a name, then for a color"

  @impl true
  def execute(%{}, ctx) do
    with {:ok, %{"name" => name}} <-
           Sake.Elicit.form(ctx, :step1, "Step 1: What is your name?", schema("name")),
         {:ok, %{"color" => color}} <-
           Sake.Elicit.form(ctx, :step2, "Step 2: What is your favorite color?", schema("color")) do
      {:ok, "#{name} likes #{color}."}
    else
      other -> {:error, "Missing input: #{inspect(other)}"}
    end
  end

  defp schema(property) do
    %{
      "type" => "object",
      "properties" => %{property => %{"type" => "string"}},
      "required" => [property]
    }
  end
end
