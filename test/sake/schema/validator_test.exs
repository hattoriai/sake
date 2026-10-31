defmodule Sake.Schema.ValidatorTest do
  use ExUnit.Case, async: true

  alias Sake.Schema.Validator
  alias SakeDev.Conformance.Tools.JsonSchema202012Tool

  defp valid?(schema, value), do: Validator.validate(schema, value) == :ok

  defp errors(schema, value) do
    {:error, errors} = Validator.validate(schema, value)
    Enum.map(errors, &{Enum.join(&1.path, "."), &1.message})
  end

  describe "references" do
    test "$ref to $defs, to an $anchor, to the root, and through an $id" do
      schema = %{
        "$id" => "https://example.com/person.json",
        "type" => "object",
        "$defs" => %{
          "address" => %{
            "$anchor" => "addr",
            "type" => "object",
            "properties" => %{"city" => %{"type" => "string"}},
            "required" => ["city"]
          },
          "named" => %{
            "$id" => "named.json",
            "type" => "object",
            "properties" => %{"name" => %{"$ref" => "#/$defs/nonEmpty"}},
            "$defs" => %{"nonEmpty" => %{"type" => "string", "minLength" => 1}}
          }
        },
        "properties" => %{
          "home" => %{"$ref" => "#/$defs/address"},
          "work" => %{"$ref" => "#addr"},
          "boss" => %{"$ref" => "#"},
          "self" => %{"$ref" => "named.json"},
          "absolute" => %{"$ref" => "https://example.com/named.json"}
        }
      }

      assert :ok = Validator.check_schema(schema)

      assert valid?(schema, %{
               "home" => %{"city" => "Lisbon"},
               "work" => %{"city" => "Porto"},
               "boss" => %{"home" => %{"city" => "Faro"}},
               "self" => %{"name" => "Ana"},
               "absolute" => %{"name" => "Rui"}
             })

      assert errors(schema, %{
               "home" => %{},
               "work" => %{"city" => 1},
               "boss" => %{"home" => %{}},
               "self" => %{"name" => ""}
             }) == [
               {"boss.home.city", "is required"},
               {"home.city", "is required"},
               {"self.name", "must be at least 1 characters"},
               {"work.city", "must be a string"}
             ]
    end

    test "a JSON Pointer with escaped and percent-encoded tokens" do
      schema = %{
        "$defs" => %{
          "a/b" => %{"type" => "integer"},
          "c~d" => %{"type" => "string"},
          "e f" => %{"const" => 1}
        },
        "prefixItems" => [
          %{"$ref" => "#/$defs/a~1b"},
          %{"$ref" => "#/$defs/c~0d"},
          %{"$ref" => "#/$defs/e%20f"}
        ]
      }

      assert valid?(schema, [1, "x", 1])
      refute valid?(schema, ["x", 1, 2])
    end

    test "recursive schemas validate nested values" do
      tree = %{
        "type" => "object",
        "properties" => %{
          "value" => %{"type" => "integer"},
          "children" => %{"type" => "array", "items" => %{"$ref" => "#"}}
        },
        "required" => ["value"]
      }

      assert valid?(tree, %{
               "value" => 1,
               "children" => [%{"value" => 2, "children" => [%{"value" => 3}]}]
             })

      assert errors(tree, %{"value" => 1, "children" => [%{"children" => []}]}) == [
               {"children.0.value", "is required"}
             ]
    end
  end

  describe "composition" do
    test "allOf, anyOf, oneOf and not" do
      schema = %{
        "allOf" => [%{"type" => "object"}, %{"required" => ["kind"]}],
        "anyOf" => [%{"required" => ["phone"]}, %{"required" => ["email"]}],
        "oneOf" => [
          %{"properties" => %{"kind" => %{"const" => "person"}}},
          %{"properties" => %{"kind" => %{"const" => "company"}}}
        ],
        "not" => %{"required" => ["banned"]}
      }

      assert valid?(schema, %{"kind" => "person", "email" => "a@b"})

      assert errors(schema, %{"kind" => "person"}) == [
               {"", "must match at least one of the schemas in anyOf"}
             ]

      assert errors(schema, %{"phone" => "1"}) |> Enum.member?({"kind", "is required"})

      assert errors(schema, %{"kind" => "robot", "phone" => "1"}) ==
               [{"", "must match exactly one of the schemas in oneOf, matches none"}]

      assert errors(schema, %{"kind" => "person", "phone" => "1", "banned" => true}) ==
               [{"", "must not match the schema in not"}]
    end

    test "oneOf refuses a value two branches accept" do
      schema = %{"oneOf" => [%{"type" => "integer"}, %{"minimum" => 0}]}
      assert valid?(schema, -1)
      assert valid?(schema, 0.5)

      assert errors(schema, 3) == [
               {"", "must match exactly one of the schemas in oneOf, matches 2"}
             ]
    end
  end

  describe "conditions" do
    test "if/then/else, dependentRequired and dependentSchemas" do
      schema = %{
        "type" => "object",
        "properties" => %{"contactMethod" => %{"enum" => ["phone", "email"]}},
        "if" => %{
          "properties" => %{"contactMethod" => %{"const" => "phone"}},
          "required" => ["contactMethod"]
        },
        "then" => %{"required" => ["phone"]},
        "else" => %{"required" => ["email"]},
        "dependentRequired" => %{"card" => ["cvc"]},
        "dependentSchemas" => %{
          "vat" => %{
            "properties" => %{"country" => %{"minLength" => 2}},
            "required" => ["country"]
          }
        }
      }

      assert valid?(schema, %{"contactMethod" => "phone", "phone" => "1"})
      assert valid?(schema, %{"email" => "a@b"})
      assert errors(schema, %{"contactMethod" => "phone"}) == [{"phone", "is required"}]
      assert errors(schema, %{"contactMethod" => "email"}) == [{"email", "is required"}]

      assert errors(schema, %{"email" => "a", "card" => "4"}) == [
               {"cvc", "is required when card is present"}
             ]

      assert errors(schema, %{"email" => "a", "vat" => "1", "country" => "P"}) == [
               {"country", "must be at least 2 characters"}
             ]
    end
  end

  describe "objects and arrays" do
    test "patternProperties, additionalProperties, propertyNames and sizes" do
      schema = %{
        "properties" => %{"id" => %{"type" => "string"}},
        "patternProperties" => %{"^x-" => %{"type" => "integer"}},
        "additionalProperties" => false,
        "propertyNames" => %{"maxLength" => 5},
        "minProperties" => 1,
        "maxProperties" => 3
      }

      assert valid?(schema, %{"id" => "a", "x-a" => 1})
      assert errors(schema, %{"x-a" => "1"}) == [{"x-a", "must be an integer"}]

      assert errors(schema, %{"others" => 1}) == [
               {"others", "is not an accepted argument"},
               {"others", "is not an accepted property name"}
             ]

      assert errors(schema, %{}) == [{"", "must have at least 1 properties"}]
    end

    test "prefixItems, items, contains and uniqueItems" do
      schema = %{
        "type" => "array",
        "prefixItems" => [%{"type" => "string"}, %{"type" => "integer"}],
        "items" => %{"type" => "boolean"},
        "contains" => %{"const" => true},
        "maxContains" => 2,
        "uniqueItems" => false,
        "minItems" => 2
      }

      assert valid?(schema, ["a", 1, true, false])
      assert errors(schema, ["a", 1, false]) == [{"", "must contain at least 1 matching item"}]
      assert errors(schema, ["a", "b", true]) == [{"1", "must be an integer"}]

      assert errors(schema, ["a", 1, true, true, true])
             |> Enum.member?({"", "must contain at most 2 matching items"})

      assert errors(%{"uniqueItems" => true}, [1, 1.0]) == [{"", "must not have duplicate items"}]

      assert errors(%{"items" => false, "prefixItems" => [true]}, [1, 2]) == [
               {"1", "is not allowed"}
             ]
    end

    test "unevaluatedProperties sees what composition evaluated" do
      schema = %{
        "type" => "object",
        "allOf" => [%{"properties" => %{"a" => true}}],
        "if" => %{"properties" => %{"kind" => %{"const" => "b"}}, "required" => ["kind"]},
        "then" => %{"properties" => %{"b" => true}},
        "properties" => %{"kind" => true},
        "unevaluatedProperties" => false
      }

      assert valid?(schema, %{"a" => 1, "kind" => "b", "b" => 2})
      assert errors(schema, %{"a" => 1, "b" => 2}) == [{"b", "is not an accepted argument"}]
    end

    test "unevaluatedItems sees prefixItems and contains" do
      schema = %{
        "prefixItems" => [%{"type" => "string"}],
        "contains" => %{"type" => "integer"},
        "unevaluatedItems" => false
      }

      assert valid?(schema, ["a", 1, 2])
      assert errors(schema, ["a", 1, true]) == [{"2", "is not allowed"}]
    end
  end

  describe "values" do
    test "type lists, null, const, enum, numbers and strings" do
      assert valid?(%{"type" => ["string", "null"]}, nil)

      assert errors(%{"type" => ["string", "null"]}, 1) == [
               {"", "must be of type string or null"}
             ]

      assert valid?(%{"type" => "integer"}, 2.0)
      assert errors(%{"const" => %{"a" => [1]}}, %{"a" => [2]}) == [{"", ~s(must be {"a":[1]})}]
      assert valid?(%{"enum" => [1, "x", nil]}, 1.0)

      assert errors(%{"exclusiveMinimum" => 0, "multipleOf" => 0.1}, 0) == [
               {"", "must be greater than 0"}
             ]

      assert valid?(%{"multipleOf" => 0.1}, 0.3)
      assert errors(%{"multipleOf" => 3}, 7) == [{"", "must be a multiple of 3"}]
      assert valid?(%{"maxLength" => 2, "pattern" => "^é"}, "éa")
      assert valid?(false, 1) == false
      assert valid?(true, nil)
    end

    test "format and unknown keywords are annotations" do
      assert valid?(
               %{"format" => "email", "x-mcp-header" => "X-Id", "title" => "t"},
               "not an email"
             )
    end
  end

  describe "what it refuses" do
    test "another dialect, $dynamicRef, an unresolved or remote $ref, a bad pattern" do
      assert {:error, "the dialect" <> _} =
               Validator.check_schema(%{"$schema" => "http://json-schema.org/draft-07/schema#"})

      assert :ok =
               Validator.check_schema(%{
                 "$schema" => "https://json-schema.org/draft/2020-12/schema"
               })

      assert {:error, message} = Validator.check_schema(%{"items" => %{"$dynamicRef" => "#meta"}})
      assert message =~ "$dynamicRef"

      assert {:error, message} =
               Validator.check_schema(%{"properties" => %{"a" => %{"$ref" => "#/$defs/missing"}}})

      assert message =~ "#/properties/a: the $ref \"#/$defs/missing\" does not resolve"

      assert {:error, _} = Validator.check_schema(%{"$ref" => "https://example.com/remote.json"})
      assert {:error, _} = Validator.check_schema(%{"pattern" => "("})

      assert {:error, [%{message: "the schema's $ref" <> _}]} =
               Validator.validate(%{"$ref" => "https://example.com/remote.json"}, 1)
    end

    test "its work is bounded" do
      # A reference loop that consumes no input never ends by itself.
      assert {:error, [%{message: "the schema's references nest too deep"}]} =
               Validator.validate(%{"$ref" => "#"}, 1)

      # Exponential branching: each level doubles the work.
      wide =
        Enum.reduce(1..15, %{"type" => "integer"}, fn _, inner -> %{"anyOf" => [inner, inner]} end)

      assert :ok = Validator.check_schema(wide)

      assert {:error, [%{message: "the schema took too much work to validate"}]} =
               Validator.validate(%{"items" => wide}, List.duplicate("x", 10))

      # A schema with more schemas in it than one validation may evaluate.
      huge =
        Enum.reduce(1..20, %{"type" => "integer"}, fn _, inner -> %{"anyOf" => [inner, inner]} end)

      assert {:error, "the schema is too large to validate against"} =
               Validator.check_schema(huge)

      assert {:error, [%{message: "the schema is too large" <> _}]} = Validator.validate(huge, 1)
    end
  end

  test "the conformance suite's 2020-12 schema validates what it describes" do
    schema = JsonSchema202012Tool.spec().input_schema

    assert valid?(schema, %{"name" => "Ana", "contactMethod" => "phone", "phone" => "1"})
    assert valid?(schema, %{"email" => "a@b", "address" => %{"city" => "Lisbon"}})

    assert errors(schema, %{"contactMethod" => "phone", "email" => "a@b"}) == [
             {"phone", "is required"}
           ]

    assert errors(schema, %{"address" => %{"city" => 1}, "email" => "a"}) == [
             {"address.city", "must be a string"}
           ]

    assert errors(schema, %{"email" => "a", "fax" => "1"}) == [
             {"fax", "is not an accepted argument"}
           ]
  end
end
