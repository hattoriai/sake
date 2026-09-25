defmodule Sake.ToolTest do
  use ExUnit.Case, async: true

  defmodule Search do
    use Sake.Tool,
      name: "search_issues",
      title: "Search issues",
      description: "Search issues by text",
      scope: "issues:read",
      annotations: [read_only: true, idempotent: true],
      icons: [%{src: "https://example.com/i.png", mime_type: "image/png", sizes: ["48x48"]}],
      ttl: 60_000

    arg :query, :string, required: true
    arg :limit, :integer, default: 20, max: 100
    arg :region, :string, header: "Region"

    output do
      arg :count, :integer, required: true
    end

    @impl true
    def execute(%{query: q, limit: n}, _ctx), do: {:ok, %{count: String.length(q) + n}}
  end

  defmodule Bare do
    use Sake.Tool, name: "bare", description: "No args"
    @impl true
    def execute(_args, _ctx), do: {:ok, "ok"}
  end

  defmodule Raw do
    use Sake.Tool,
      name: "raw",
      description: "Hand schema",
      input_schema: %{"type" => "object", "properties" => %{"a" => %{"type" => "number"}}}

    @impl true
    def execute(%{a: a}, _ctx), do: {:ok, a}
  end

  test "spec from the declarations" do
    spec = Search.spec()

    assert %Sake.Tool.Spec{
             module: Search,
             name: "search_issues",
             title: "Search issues",
             scopes: ["issues:read"],
             stream: false,
             ttl: 60_000
           } = spec

    assert spec.input_schema["required"] == ["query"]
    assert spec.output_schema["properties"]["count"] == %{"type" => "integer"}
    assert spec.headers == %{"Region" => ["region"]}
    assert spec.annotations == %{read_only: true, idempotent: true}
    assert Bare.spec().input_schema == %{"type" => "object", "additionalProperties" => false}
    assert Raw.spec().input_schema["properties"]["a"] == %{"type" => "number"}
  end

  test "wire form per revision" do
    wire = Sake.Tool.Spec.to_wire(Search.spec(), "2026-07-28")
    assert wire["name"] == "search_issues"
    assert wire["title"] == "Search issues"
    assert wire["annotations"] == %{"readOnlyHint" => true, "idempotentHint" => true}

    assert wire["icons"] == [
             %{
               "src" => "https://example.com/i.png",
               "mimeType" => "image/png",
               "sizes" => ["48x48"]
             }
           ]

    assert wire["outputSchema"]["properties"]["count"]
    refute Map.has_key?(wire, "_meta")

    old = Sake.Tool.Spec.to_wire(Search.spec(), "2025-03-26")
    refute Map.has_key?(old, "title")
    refute Map.has_key?(old, "outputSchema")
    refute Map.has_key?(old, "icons")
    assert old["annotations"]["readOnlyHint"]

    mid = Sake.Tool.Spec.to_wire(Search.spec(), "2025-06-18")
    assert mid["title"] && mid["outputSchema"]
    refute Map.has_key?(mid, "icons")
  end

  test "names are checked at compile time" do
    assert_raise ArgumentError, ~r/tool name/, fn ->
      defmodule BadName do
        use Sake.Tool, name: "has space", description: "x"
        def execute(_, _), do: {:ok, "x"}
      end
    end
  end
end
