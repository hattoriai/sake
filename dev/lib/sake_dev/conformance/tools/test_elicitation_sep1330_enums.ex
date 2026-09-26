defmodule SakeDev.Conformance.Tools.TestElicitationSep1330Enums do
  @moduledoc false
  # SEP-1330: the five enum schema shapes (untitled/titled, single/multi
  # select, and the deprecated `enumNames` form).
  use Sake.Tool,
    name: "test_elicitation_sep1330_enums",
    description: "Requests elicitation with every enum schema variant"

  @impl true
  def execute(%{}, ctx) do
    schema = %{
      "type" => "object",
      "properties" => %{
        "untitledSingle" => %{"type" => "string", "enum" => ["option1", "option2", "option3"]},
        "titledSingle" => %{
          "type" => "string",
          "oneOf" => [
            %{"const" => "value1", "title" => "First Option"},
            %{"const" => "value2", "title" => "Second Option"},
            %{"const" => "value3", "title" => "Third Option"}
          ]
        },
        "legacyEnum" => %{
          "type" => "string",
          "enum" => ["opt1", "opt2", "opt3"],
          "enumNames" => ["Option One", "Option Two", "Option Three"]
        },
        "untitledMulti" => %{
          "type" => "array",
          "items" => %{"type" => "string", "enum" => ["option1", "option2", "option3"]}
        },
        "titledMulti" => %{
          "type" => "array",
          "items" => %{
            "anyOf" => [
              %{"const" => "value1", "title" => "First Choice"},
              %{"const" => "value2", "title" => "Second Choice"}
            ]
          }
        }
      }
    }

    case Sake.Elicit.form(ctx, :sep1330, "Pick a variant", schema) do
      {:ok, content} -> {:ok, "Elicitation completed: action=accept, content=#{inspect(content)}"}
      :decline -> {:ok, "Elicitation completed: action=decline"}
      :cancel -> {:ok, "Elicitation completed: action=cancel"}
      {:error, :unsupported} -> {:error, "This tool needs a client that supports elicitation."}
    end
  end
end
