defmodule SakeDev.Conformance.Tools.JsonSchema202012Tool do
  @moduledoc false
  # json-schema-2020-12: a raw input schema with 2020-12 keywords `arg`
  # lines cannot express (`$defs` with an `$anchor`, `$ref`, `allOf`/`anyOf`,
  # `if`/`then`/`else`), which `tools/list` must carry unchanged.
  use Sake.Tool,
    name: "json_schema_2020_12_tool",
    description: "Tool with JSON Schema 2020-12 features",
    input_schema: %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "$defs" => %{
        "address" => %{
          "$anchor" => "addressDef",
          "type" => "object",
          "properties" => %{"street" => %{"type" => "string"}, "city" => %{"type" => "string"}}
        }
      },
      "properties" => %{
        "name" => %{"type" => "string"},
        "address" => %{"$ref" => "#/$defs/address"},
        "contactMethod" => %{"type" => "string", "enum" => ["phone", "email"]},
        "phone" => %{"type" => "string"},
        "email" => %{"type" => "string"}
      },
      "allOf" => [%{"anyOf" => [%{"required" => ["phone"]}, %{"required" => ["email"]}]}],
      "if" => %{
        "properties" => %{"contactMethod" => %{"const" => "phone"}},
        "required" => ["contactMethod"]
      },
      "then" => %{"required" => ["phone"]},
      "else" => %{"required" => ["email"]},
      "additionalProperties" => false
    }

  @impl true
  def execute(_args, _ctx), do: {:ok, "Schema received."}
end
