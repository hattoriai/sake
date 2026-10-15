defmodule SakeDev.Conformance.Tools.TestInputRequiredResultTamperedState do
  @moduledoc false
  use Sake.Tool,
    name: "test_input_required_result_tampered_state",
    description: "Asks for a confirmation; a tampered request state is refused"

  @impl true
  def execute(%{}, ctx) do
    case Sake.Elicit.form(ctx, :confirm, "Please confirm", %{
           "type" => "object",
           "properties" => %{"ok" => %{"type" => "boolean"}},
           "required" => ["ok"]
         }) do
      {:ok, _} -> {:ok, "Confirmed."}
      other -> {:error, "Not confirmed: #{inspect(other)}"}
    end
  end
end
