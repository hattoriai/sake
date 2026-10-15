defmodule SakeDev.Conformance.Tools.TestInputRequiredResultRequestState do
  @moduledoc false
  # Sake signs and verifies every `requestState` itself, so reaching the
  # second round at all means the state was validated.
  use Sake.Tool,
    name: "test_input_required_result_request_state",
    description: "Asks for a confirmation, carrying a request state"

  @impl true
  def execute(%{}, ctx) do
    case Sake.Elicit.form(ctx, :confirm, "Please confirm", %{
           "type" => "object",
           "properties" => %{"ok" => %{"type" => "boolean"}},
           "required" => ["ok"]
         }) do
      {:ok, _} -> {:ok, "state-ok: confirmed"}
      other -> {:error, "Not confirmed: #{inspect(other)}"}
    end
  end
end
