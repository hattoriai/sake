defmodule SakeDev.Conformance.Tools.MultiInput do
  @moduledoc false
  use Sake.Tool,
    name: "multi_input",
    description: "Asks two questions at once",
    task: :optional

  @schema %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}, "confirm" => %{"type" => "boolean"}}
  }

  @impl true
  def execute(%{}, ctx) do
    answers =
      Sake.Input.all(ctx, [
        &Sake.Elicit.form(&1, :first, "First question", @schema),
        &Sake.Elicit.form(&1, :second, "Second question", @schema)
      ])

    names = for {:ok, %{"name" => name}} <- answers, do: name
    {:ok, "Answered: #{Enum.join(names, ", ")}"}
  end
end
