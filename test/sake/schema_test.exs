defmodule Sake.SchemaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sake.Schema

  @args [
    {:query, :string, required: true, description: "Free text", min_length: 1},
    {:limit, :integer, default: 20, min: 1, max: 100},
    {:region, :string, header: "Region"},
    {:tags, {:array, :string}, []},
    {:kind, {:enum, ["bug", "task"]}, []},
    {:filter, {:object, [{:open, :boolean, []}, {:since, :string, format: "date-time"}]}, []},
    {:extra, :any, []}
  ]

  test "builds JSON Schema 2020-12" do
    schema = Schema.build(@args)

    assert schema == %{
             "type" => "object",
             "properties" => %{
               "query" => %{"type" => "string", "description" => "Free text", "minLength" => 1},
               "limit" => %{
                 "type" => "integer",
                 "default" => 20,
                 "minimum" => 1,
                 "maximum" => 100
               },
               "region" => %{"type" => "string", "x-mcp-header" => "Region"},
               "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
               "kind" => %{"type" => "string", "enum" => ["bug", "task"]},
               "filter" => %{
                 "type" => "object",
                 "properties" => %{
                   "open" => %{"type" => "boolean"},
                   "since" => %{"type" => "string", "format" => "date-time"}
                 },
                 "additionalProperties" => false
               },
               "extra" => %{}
             },
             "required" => ["query"],
             "additionalProperties" => false
           }
  end

  test "no args gives the recommended empty object schema" do
    assert Schema.build([]) == %{"type" => "object", "additionalProperties" => false}
  end

  test "validate coerces keys, applies defaults, reports paths" do
    schema = Schema.build(@args)

    assert {:ok, %{query: "x", limit: 20, tags: [], filter: nil}} =
             Schema.validate(schema, %{"query" => "x", "tags" => []})

    assert {:ok, %{limit: 5}} = Schema.validate(schema, %{"query" => "x", "limit" => 5})
    assert {:ok, %{limit: 5}} = Schema.validate(schema, %{"query" => "x", "limit" => 5.0})
    assert {:error, [%{path: ["query"], message: "is required"}]} = Schema.validate(schema, %{})

    assert {:error, [%{path: ["limit"], message: "must be at most 100"}]} =
             Schema.validate(schema, %{"query" => "x", "limit" => 101})

    assert {:error, [%{path: ["limit"], message: "must be an integer"}]} =
             Schema.validate(schema, %{"query" => "x", "limit" => "5"})

    assert {:error, [%{path: ["kind"], message: "must be one of bug, task"}]} =
             Schema.validate(schema, %{"query" => "x", "kind" => "epic"})

    assert {:error, [%{path: ["filter", "open"], message: "must be a boolean"}]} =
             Schema.validate(schema, %{"query" => "x", "filter" => %{"open" => 1}})

    assert {:error, [%{path: ["nope"], message: "is not an accepted argument"}]} =
             Schema.validate(schema, %{"query" => "x", "nope" => 1})

    assert {:error, [%{path: ["tags", "1"], message: "must be a string"}]} =
             Schema.validate(schema, %{"query" => "x", "tags" => ["a", 2]})

    assert {:ok, %{filter: %{open: true, since: nil}}} =
             Schema.validate(schema, %{"query" => "x", "filter" => %{"open" => true}})
  end

  test "validate accepts atom-keyed input and a hand-written schema" do
    schema = %{
      "type" => "object",
      "properties" => %{"a" => %{"type" => "number"}},
      "required" => ["a"]
    }

    assert {:ok, %{a: 1.5}} = Schema.validate(schema, %{a: 1.5})
    assert {:ok, %{"b" => "kept", a: 1}} = Schema.validate(schema, %{"a" => 1, "b" => "kept"})

    # The name is built at runtime so no atom for it exists before validate/2 runs.
    name = "zq_novel_" <> Integer.to_string(System.unique_integer([:positive]))
    schema2 = %{"type" => "object", "properties" => %{name => %{"type" => "integer"}}}
    assert {:ok, result} = Schema.validate(schema2, %{name => 1})
    assert Enum.map(Map.keys(result), &Atom.to_string/1) == [name]
    assert Map.values(result) == [1]
  end

  test "pattern and length" do
    schema = Schema.build([{:code, :string, pattern: "^[A-Z]{3}$", max_length: 3}])
    assert {:ok, %{code: "ABC"}} = Schema.validate(schema, %{"code" => "ABC"})

    assert {:error, [%{path: ["code"], message: "does not match ^[A-Z]{3}$"}]} =
             Schema.validate(schema, %{"code" => "abc"})
  end

  test "header paths and header name rules" do
    schema = Schema.build(@args)
    assert Schema.header_paths(schema) == %{"Region" => ["region"]}
    assert Schema.valid_header_name?("Region")
    refute Schema.valid_header_name?("")
    refute Schema.valid_header_name?("Re gion")
    refute Schema.valid_header_name?("X\r\nY")

    nested = Schema.build([{:a, {:object, [{:b, :integer, header: "B"}]}, []}])
    assert Schema.header_paths(nested) == %{"B" => ["a", "b"]}
  end

  test "build rejects a header on a non-primitive, a number, or a duplicate name" do
    assert_raise ArgumentError, ~r/header/, fn ->
      Schema.build([{:t, {:array, :string}, header: "T"}])
    end

    assert_raise ArgumentError, ~r/header/, fn -> Schema.build([{:n, :number, header: "N"}]) end

    assert_raise ArgumentError, ~r/header/, fn ->
      Schema.build([{:a, :string, header: "X"}, {:b, :string, header: "x"}])
    end

    assert_raise ArgumentError, ~r/unique/, fn ->
      Schema.build([{:a, :string, header: "X"}, {:b, :string, header: "X"}])
    end
  end

  test "header entries keep a name that is used twice" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "a" => %{"type" => "string", "x-mcp-header" => "Region"},
        "b" => %{"type" => "string", "x-mcp-header" => "Region"}
      }
    }

    assert Schema.header_entries(schema) == [{"Region", ["a"]}, {"Region", ["b"]}]
  end

  property "a valid value for a built schema validates" do
    schema =
      Schema.build([
        {:n, :integer, min: 0, max: 10},
        {:s, :string, max_length: 5},
        {:b, :boolean, []}
      ])

    check all(n <- integer(0..10), s <- string(:alphanumeric, max_length: 5), b <- boolean()) do
      assert {:ok, %{n: ^n, s: ^s, b: ^b}} =
               Schema.validate(schema, %{"n" => n, "s" => s, "b" => b})
    end
  end
end
