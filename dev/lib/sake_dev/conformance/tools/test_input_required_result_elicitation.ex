defmodule SakeDev.Conformance.Tools.TestInputRequiredResultElicitation do
  @moduledoc false
  # SEP-2322: one elicitation through an input-required result. Several
  # input-required-result-* scenarios share it.
  use Sake.Tool,
    name: "test_input_required_result_elicitation",
    description: "Asks for a name through an input-required result"

  @impl true
  def execute(%{}, ctx) do
    schema = %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}},
      "required" => ["name"]
    }

    case Sake.Elicit.form(ctx, :user_name, "What is your name?", schema) do
      {:ok, %{"name" => name}} -> {:ok, "Hello, #{name}!"}
      {:ok, _content} -> {:ok, "Hello!"}
      :decline -> {:ok, "No name given."}
      :cancel -> {:error, "Cancelled."}
      {:error, :unsupported} -> {:error, "This tool needs a client that supports elicitation."}
    end
  end
end
