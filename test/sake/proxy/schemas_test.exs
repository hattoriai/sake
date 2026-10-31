defmodule Sake.Proxy.SchemasTest do
  # Proxies are named processes, started with each test's upstream URL.
  use ExUnit.Case, async: false

  import Sake.Test

  alias Sake.Client.ToolResult
  alias SakeTest.HTTP

  @untyped %{
    "$defs" => %{"id" => %{"type" => "string", "minLength" => 2}},
    "properties" => %{"id" => %{"$ref" => "#/$defs/id"}, "mode" => %{"enum" => ["a", "b"]}},
    "oneOf" => [%{"required" => ["id"]}, %{"required" => ["mode"]}]
  }

  defmodule Untyped do
    use Sake.Tool,
      name: "untyped",
      description: "An input schema without a top-level type",
      input_schema: %{
        "$defs" => %{"id" => %{"type" => "string", "minLength" => 2}},
        "properties" => %{"id" => %{"$ref" => "#/$defs/id"}, "mode" => %{"enum" => ["a", "b"]}},
        "oneOf" => [%{"required" => ["id"]}, %{"required" => ["mode"]}]
      },
      output_schema: %{"type" => "array", "items" => %{"type" => "string"}}

    @impl true
    def execute(_args, _ctx), do: {:ok, Sake.Tool.Result.new(structured: [])}
  end

  defmodule Nothing do
    use Sake.Tool, name: "nothing", description: "A null structured result"

    @impl true
    def execute(_args, _ctx), do: {:ok, Sake.Tool.Result.new(structured: nil, text: "none")}
  end

  defmodule Upstream do
    use Sake.Server, name: "schemas-upstream", version: "1"
    tools [Untyped, Nothing]
  end

  defmodule Router do
    use Plug.Router
    plug :match
    plug :dispatch

    forward "/mcp",
      to: Sake.Plug,
      init_opts: [server: Sake.Proxy.SchemasTest.Upstream, secret: String.duplicate("u", 64)]
  end

  defmodule Proxy do
    use Sake.Proxy, name: "schemas-proxy", version: "1", upstream: "http://127.0.0.1:1/mcp"
  end

  defmodule Gateway do
    use Sake.Server, name: "schemas-gateway", version: "1"
    mount Proxy, prefix: "up"
  end

  setup do
    start_supervised!({Proxy, upstream: HTTP.start(Router) <> "/mcp"})
    :ok
  end

  test "an input schema without a top-level type keeps its constraints, mounted too" do
    for {server, name} <- [{Proxy, "untyped"}, {Gateway, "up_untyped"}] do
      {:ok, tools} = list_tools(connect(server))
      tool = Enum.find(tools, &(&1.name == name))

      # The arguments of a tool are always an object: the type is added,
      # and nothing else changes.
      assert tool.input_schema == Map.put(@untyped, "type", "object")
      assert tool.output_schema == %{"type" => "array", "items" => %{"type" => "string"}}
    end
  end

  test "the upstream validates the proxied arguments against its whole schema" do
    client = connect(Gateway)

    assert {:ok, %ToolResult{is_error: false}} = call_tool(client, "up_untyped", %{"id" => "ab"})

    assert {:ok, %ToolResult{is_error: true, text: "Invalid arguments: " <> _}} =
             call_tool(client, "up_untyped", %{"id" => "ab", "mode" => "a"})
  end

  test "a structured [] or null comes through on 2026-07-28, and is left out before it" do
    client = connect(Gateway)

    assert {:ok, %ToolResult{structured: []}} = call_tool(client, "up_untyped", %{"id" => "ab"})

    raw = fn client ->
      {:ok, result, _} =
        Sake.Client.request(session(client), "tools/call", %{
          "name" => "up_nothing",
          "arguments" => %{}
        })

      result
    end

    assert %{"structuredContent" => nil, "content" => [%{"text" => "none"}]} = raw.(client)
    refute Map.has_key?(raw.(connect(Gateway, era: :legacy)), "structuredContent")
  end
end
