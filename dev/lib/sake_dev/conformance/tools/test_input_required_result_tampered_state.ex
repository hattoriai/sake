defmodule SakeDev.Conformance.Tools.TestInputRequiredResultTamperedState do
  @moduledoc false
  # SEP-2322: a retry with a modified `requestState` is refused. Sake signs
  # the state, so the fixture only has to ask something.
  use Sake.Tool,
    name: "test_input_required_result_tampered_state",
    description: "Asks for a confirmation behind a signed request state"

  @impl true
  def execute(%{}, ctx) do
    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    case Sake.Elicit.form(ctx, :confirm, "Please confirm", schema) do
      {:ok, _content} -> {:ok, "Confirmed."}
      {:error, :unsupported} -> {:error, "This tool needs a client that supports elicitation."}
      _ -> {:ok, "Not confirmed."}
    end
  end
end
