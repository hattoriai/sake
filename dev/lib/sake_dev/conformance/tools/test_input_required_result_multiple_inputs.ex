defmodule SakeDev.Conformance.Tools.TestInputRequiredResultMultipleInputs do
  @moduledoc false
  use Sake.Tool,
    name: "test_input_required_result_multiple_inputs",
    description: "Asks for a name, a greeting and the roots at once"

  @impl true
  def execute(%{}, ctx) do
    [name, greeting, roots] =
      Sake.Input.all(ctx, [
        &Sake.Elicit.form(&1, :user_name, "What is your name?", %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "required" => ["name"]
        }),
        &Sake.Sampling.create_message(&1, :greeting, [user: "Generate a greeting"],
          max_tokens: 50
        ),
        &Sake.Roots.list(&1, :client_roots)
      ])

    with {:ok, %{"name" => name}} <- name,
         {:ok, %{text: greeting}} <- greeting,
         {:ok, roots} <- roots do
      {:ok, "#{greeting} #{name} (#{length(roots)} roots)"}
    else
      other -> {:error, "Missing input: #{inspect(other)}"}
    end
  end
end
