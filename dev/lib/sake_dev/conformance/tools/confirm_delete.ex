defmodule SakeDev.Conformance.Tools.ConfirmDelete do
  @moduledoc false
  use Sake.Tool,
    name: "confirm_delete",
    description: "Asks for a confirmation, then pretends to delete a file",
    task: :optional

  arg :filename, :string, required: true

  @impl true
  def execute(%{filename: filename}, ctx) do
    case Sake.Elicit.form(ctx, :confirm, "Delete #{filename}?", %{
           "type" => "object",
           "properties" => %{"confirm" => %{"type" => "boolean"}},
           "required" => ["confirm"]
         }) do
      {:ok, %{"confirm" => true}} -> {:ok, "Deleted #{filename}."}
      _ -> {:ok, "Kept #{filename}."}
    end
  end
end
