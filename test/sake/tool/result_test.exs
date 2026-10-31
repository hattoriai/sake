defmodule Sake.Tool.ResultTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Sake.Test

  alias Sake.Client.ToolResult
  alias Sake.Tool.Result

  # ---- a tool with a raw 2020-12 schema

  defmodule Contact do
    use Sake.Tool,
      name: "contact",
      description: "Records a contact",
      input_schema: %{
        "type" => "object",
        "$defs" => %{"phone" => %{"type" => "string", "pattern" => "^\\+?[0-9 ]+$"}},
        "properties" => %{
          "method" => %{"enum" => ["phone", "email"]},
          "phone" => %{"$ref" => "#/$defs/phone"},
          "email" => %{"type" => "string"}
        },
        "required" => ["method"],
        "if" => %{"properties" => %{"method" => %{"const" => "phone"}}},
        "then" => %{"required" => ["phone"]},
        "else" => %{"required" => ["email"]},
        "additionalProperties" => false
      }

    @impl true
    def execute(args, _ctx), do: {:ok, "recorded #{args.method}"}
  end

  # ---- explicit results

  defmodule Structured do
    use Sake.Tool, name: "structured", description: "Returns the structured value it is given"

    arg :kind, :string, required: true

    @values %{
      "empty" => [],
      "null" => nil,
      "string" => "ok",
      "number" => 42,
      "float" => 1.5,
      "boolean" => false,
      "object" => %{"a" => 1}
    }

    @impl true
    def execute(%{kind: "text"}, _ctx),
      do:
        {:ok, Result.new(structured: [], text: "no issues", meta: %{"m" => 1}), meta: %{"n" => 2}}

    def execute(%{kind: "error"}, _ctx),
      do: {:ok, Result.new(structured: %{"code" => "E1"}, text: "failed", error: true)}

    def execute(%{kind: "content"}, _ctx),
      do: {:ok, Result.new(structured: true, content: [Sake.Content.text("yes")])}

    def execute(%{kind: "none"}, _ctx), do: {:ok, Result.new(text: "just text")}
    def execute(%{kind: kind}, _ctx), do: {:ok, Result.new(structured: Map.fetch!(@values, kind))}
  end

  defmodule Listing do
    use Sake.Tool, name: "listing", description: "Returns a list, the convenient way"

    @impl true
    def execute(_args, _ctx), do: {:ok, [%{"id" => 1}]}
  end

  # ---- output schemas

  defmodule Counted do
    use Sake.Tool, name: "counted", description: "Counts, honestly or not"
    arg :honest, :boolean, required: true

    output do
      arg :count, :integer, required: true
    end

    @impl true
    def execute(%{honest: true}, _ctx), do: {:ok, %{count: 3}}
    def execute(%{honest: false}, _ctx), do: {:ok, %{count: "three"}}
  end

  defmodule Strict do
    use Sake.Tool,
      name: "strict",
      description: "Refuses to return what its schema does not describe",
      validate_output: :error,
      output_schema: %{"type" => "array", "items" => %{"type" => "integer"}}

    arg :items, {:array, :string}, required: true

    @impl true
    def execute(%{items: items}, _ctx), do: {:ok, Result.new(structured: items)}
  end

  defmodule Things do
    use Sake.Server, name: "things", version: "1"
    tools [Contact, Structured, Listing, Counted, Strict]
  end

  describe "a raw 2020-12 input schema" do
    test "is validated with its references and conditions" do
      client = connect(Things)

      assert {:ok, %ToolResult{text: "recorded phone"}} =
               call_tool(client, "contact", %{"method" => "phone", "phone" => "+351 21"})

      assert {:ok, %ToolResult{is_error: true, text: text}} =
               call_tool(client, "contact", %{"method" => "phone", "email" => "a@b"})

      assert text == "Invalid arguments: phone: is required"

      assert {:ok,
              %ToolResult{is_error: true, text: "Invalid arguments: phone: does not match" <> _}} =
               call_tool(client, "contact", %{"method" => "phone", "phone" => "call me"})

      assert {:ok, %ToolResult{is_error: true, text: "Invalid arguments: email: is required"}} =
               call_tool(client, "contact", %{"method" => "email"})

      assert {:ok,
              %ToolResult{
                is_error: true,
                text: "Invalid arguments: fax: is not an accepted argument"
              }} =
               call_tool(client, "contact", %{"method" => "email", "email" => "a", "fax" => "1"})
    end

    test "is listed as written" do
      {:ok, tools} = list_tools(connect(Things))
      contact = Enum.find(tools, &(&1.name == "contact"))
      assert contact.input_schema == Contact.spec().input_schema
    end

    test "is refused when it compiles if Sake cannot validate against all of it" do
      for {schema, message} <- [
            {~s(%{"$schema" => "http://json-schema.org/draft-07/schema#", "type" => "object"}),
             "dialect"},
            {~s(%{"type" => "object", "properties" => %{"a" => %{"$ref" => "#/$defs/a"}}}),
             "does not resolve"},
            {~s(%{"type" => "object", "$ref" => "https://example.com/s.json"}),
             "does not resolve"},
            {~s(%{"type" => "object", "items" => %{"$dynamicRef" => "#x"}}), "$dynamicRef"}
          ] do
        source = """
        defmodule Sake.Tool.ResultTest.Bad#{System.unique_integer([:positive])} do
          use Sake.Tool, name: "bad", input_schema: #{schema}
          def execute(_args, _ctx), do: {:ok, "no"}
        end
        """

        error = assert_raise ArgumentError, fn -> Code.compile_string(source) end
        assert error.message =~ "input_schema: "
        assert error.message =~ message
      end
    end
  end

  describe "Sake.Tool.Result on 2026-07-28" do
    test "carries any JSON value as structuredContent, with its JSON for the model" do
      client = connect(Things)

      for {kind, value, text} <- [
            {"empty", [], "[]"},
            {"null", nil, "null"},
            {"string", "ok", ~s("ok")},
            {"number", 42, "42"},
            {"float", 1.5, "1.5"},
            {"boolean", false, "false"},
            {"object", %{"a" => 1}, ~s({"a":1})}
          ] do
        assert {:ok,
                %{
                  "structuredContent" => ^value,
                  "content" => [%{"text" => ^text}],
                  "isError" => false
                } = raw} =
                 call_raw(client, kind)

        assert Map.has_key?(raw, "structuredContent")
      end
    end

    test "takes the model's text or content, _meta and isError on their own" do
      client = connect(Things)

      assert {:ok,
              %{
                "structuredContent" => [],
                "content" => [%{"type" => "text", "text" => "no issues"}],
                "_meta" => %{"m" => 1, "n" => 2}
              }} = call_raw(client, "text")

      assert {:ok, %{"structuredContent" => %{"code" => "E1"}, "isError" => true}} =
               call_raw(client, "error")

      assert {:ok, %{"structuredContent" => true, "content" => [%{"text" => "yes"}]}} =
               call_raw(client, "content")

      assert {:ok, raw} = call_raw(client, "none")
      refute Map.has_key?(raw, "structuredContent")
    end

    test "new/1 refuses options it does not know, and text: with content:" do
      assert_raise ArgumentError, fn -> Result.new(structure: 1) end
      assert_raise ArgumentError, fn -> Result.new(text: "a", content: []) end
    end
  end

  describe "on a revision before 2026-07-28" do
    test "a structured value that is not an object is left out; its JSON stays the model's" do
      client = connect(Things, era: :legacy)

      for kind <- ["empty", "null", "string", "number", "boolean"] do
        assert {:ok, raw} = call_raw(client, kind)
        refute Map.has_key?(raw, "structuredContent"), kind
        assert [%{"text" => _}] = raw["content"]
      end

      assert {:ok, %{"structuredContent" => %{"a" => 1}}} = call_raw(client, "object")

      # So is a list result's, which was sent as an array before.
      assert {:ok, %ToolResult{structured: nil, text: ~s([{"id":1}])}} =
               call_tool(client, "listing", %{})
    end

    test "a list result keeps its structuredContent on 2026-07-28" do
      assert {:ok, %ToolResult{structured: [%{"id" => 1}]}} =
               call_tool(connect(Things), "listing", %{})
    end

    test "an output schema whose root is not an object is listed from 2026-07-28 only" do
      {:ok, tools} = list_tools(connect(Things))
      assert Enum.find(tools, &(&1.name == "strict")).output_schema["type"] == "array"
      assert Enum.find(tools, &(&1.name == "counted")).output_schema["type"] == "object"

      {:ok, tools} = list_tools(connect(Things, era: :legacy))
      assert Enum.find(tools, &(&1.name == "strict")).output_schema == nil
      assert Enum.find(tools, &(&1.name == "counted")).output_schema["type"] == "object"
    end
  end

  describe "output validation" do
    test "a result that does not match the output schema is logged by default" do
      client = connect(Things)

      assert {:ok, %ToolResult{structured: %{"count" => 3}}} =
               call_tool(client, "counted", %{"honest" => true})

      log =
        capture_log(fn ->
          assert {:ok, %ToolResult{is_error: false, structured: %{"count" => "three"}}} =
                   call_tool(client, "counted", %{"honest" => false})
        end)

      assert log =~
               "tool counted: the result does not match its output schema: count: must be an integer"
    end

    test "with validate_output: :error, the client gets a tool error instead" do
      client = connect(Things)
      assert {:ok, %ToolResult{structured: []}} = call_tool(client, "strict", %{"items" => []})

      assert {:ok, %ToolResult{is_error: true, structured: nil, text: text}} =
               call_tool(client, "strict", %{"items" => ["a"]})

      assert text == "The tool's result does not match its output schema: 0: must be an integer"
    end
  end

  defp call_raw(client, kind) do
    session = session(client)

    case Sake.Client.request(session, "tools/call", %{
           "name" => "structured",
           "arguments" => %{"kind" => kind}
         }) do
      {:ok, result, _session} -> {:ok, result}
      {:error, reason, _session} -> {:error, reason}
    end
  end
end
