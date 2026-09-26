defmodule SakeDev.Conformance.Tools.TestElicitationSep1034Defaults do
  @moduledoc false
  # SEP-1034: default values for every primitive schema type.
  use Sake.Tool,
    name: "test_elicitation_sep1034_defaults",
    description: "Requests elicitation with default values for every primitive type"

  @impl true
  def execute(%{}, ctx) do
    schema = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "default" => "John Doe"},
        "age" => %{"type" => "integer", "default" => 30},
        "score" => %{"type" => "number", "default" => 95.5},
        "status" => %{
          "type" => "string",
          "enum" => ["active", "inactive", "pending"],
          "default" => "active"
        },
        "verified" => %{"type" => "boolean", "default" => true}
      }
    }

    case Sake.Elicit.form(ctx, :sep1034, "Confirm the defaults", schema) do
      {:ok, content} -> {:ok, "Elicitation completed: action=accept, content=#{inspect(content)}"}
      :decline -> {:ok, "Elicitation completed: action=decline"}
      :cancel -> {:ok, "Elicitation completed: action=cancel"}
      {:error, :unsupported} -> {:error, "This tool needs a client that supports elicitation."}
    end
  end
end
