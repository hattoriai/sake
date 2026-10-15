defmodule SakeDev.Conformance.Tools.TestInputRequiredResultElicitation do
  @moduledoc false
  use Sake.Tool,
    name: "test_input_required_result_elicitation",
    description: "Asks for a name, then greets"

  @impl true
  def execute(%{}, ctx) do
    case Sake.Elicit.form(ctx, :user_name, "What is your name?", %{
           "type" => "object",
           "properties" => %{"name" => %{"type" => "string"}},
           "required" => ["name"]
         }) do
      {:ok, %{"name" => name}} -> {:ok, "Hello, #{name}!"}
      other -> {:error, "No name: #{inspect(other)}"}
    end
  end
end
