defmodule SakeDev.Conformance.Tools.TestInputRequiredResultRequestState do
  @moduledoc false
  # SEP-2322: the retry must echo `requestState`. Sake verifies the signed
  # state itself before the handler runs again, so reaching the answer at
  # all means the state checked out.
  use Sake.Tool,
    name: "test_input_required_result_request_state",
    description: "Asks for a confirmation and checks the echoed request state"

  @impl true
  def execute(%{}, ctx) do
    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    case Sake.Elicit.form(ctx, :confirm, "Please confirm", schema) do
      {:ok, _content} -> {:ok, "state-ok: confirmed"}
      :decline -> {:ok, "state-ok: declined"}
      :cancel -> {:error, "Cancelled."}
      {:error, :unsupported} -> {:error, "This tool needs a client that supports elicitation."}
    end
  end
end
