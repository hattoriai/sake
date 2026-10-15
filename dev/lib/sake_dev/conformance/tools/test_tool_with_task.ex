defmodule SakeDev.Conformance.Tools.TestToolWithTask do
  @moduledoc false
  # Asks for the name on the original request (multi round-trip), then
  # runs as a task.
  use Sake.Tool,
    name: "test_tool_with_task",
    description: "Asks for a name, then greets from a task",
    task: :required

  @impl true
  def prepare(args, ctx) do
    case Sake.Elicit.form(ctx, :user_name, "What is your name?", %{
           "type" => "object",
           "properties" => %{"name" => %{"type" => "string"}},
           "required" => ["name"]
         }) do
      {:ok, %{"name" => name}} -> {:ok, Map.put(args, :name, name)}
      _ -> {:error, "No name, no greeting."}
    end
  end

  @impl true
  def execute(%{name: name}, _ctx), do: {:ok, "Hello, #{name}!"}
end
