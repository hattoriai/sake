defmodule Sake.Server.DispatchTest do
  use ExUnit.Case, async: true

  alias Sake.Context
  alias Sake.Server.Dispatch

  @secret String.duplicate("s", 64)

  defp ctx(opts \\ []) do
    Context.new(
      Keyword.merge([server: SakeDev.Server, secret: @secret, client_capabilities: %{}], opts)
    )
  end

  defp call(method, params \\ %{}, ctx \\ ctx()),
    do: Dispatch.handle(SakeDev.Server, {:request, 1, method, params}, ctx)

  test "server/discover" do
    assert {:reply, r} = call("server/discover")
    assert r["resultType"] == "complete"
    assert r["supportedVersions"] == ["2026-07-28"]
    assert r["capabilities"]["tools"] == %{"listChanged" => true}

    assert r["_meta"]["io.modelcontextprotocol/serverInfo"] == %{
             "name" => "sake-dev",
             "version" => Sake.version()
           }

    assert r["instructions"] =~ "example"
    assert r["ttlMs"] == 300_000 and r["cacheScope"] == "public"
  end

  test "tools/list with cache fields, deterministic order and pagination" do
    assert {:reply, r} = call("tools/list")
    assert Enum.map(r["tools"], & &1["name"]) == ["echo", "add", "slow", "confirm", "connect"]
    assert r["ttlMs"] == 300_000 and r["cacheScope"] == "public"
    refute Map.has_key?(r, "nextCursor")

    defmodule Paged do
      use Sake.Server, name: "paged", version: "1", page_size: 2
      tools [SakeDev.Tools.Echo, SakeDev.Tools.Add, SakeDev.Tools.Slow]
    end

    assert {:reply, page1} =
             Dispatch.handle(Paged, {:request, 1, "tools/list", %{}}, ctx(server: Paged))

    assert Enum.map(page1["tools"], & &1["name"]) == ["echo", "add"]

    assert {:reply, page2} =
             Dispatch.handle(
               Paged,
               {:request, 2, "tools/list", %{"cursor" => page1["nextCursor"]}},
               ctx(server: Paged)
             )

    assert Enum.map(page2["tools"], & &1["name"]) == ["slow"]
    refute Map.has_key?(page2, "nextCursor")
    assert {:error, %{"code" => -32_602}} = call("tools/list", %{"cursor" => "junk"})
  end

  test "private cache scope and scope gating with a token" do
    ctx = ctx(token: %{}, scopes: ["issues:read"])
    assert {:reply, r} = call("tools/list", %{}, ctx)
    assert Enum.map(r["tools"], & &1["name"]) == ["echo", "add", "confirm", "connect"]
    assert r["cacheScope"] == "private"

    assert {:forbidden, ["issues:write"]} =
             call("tools/call", %{"name" => "slow", "arguments" => %{}}, ctx)

    assert {:reply, %{"resources" => [%{"uri" => "dev://readme"}]}} =
             call("resources/list", %{}, %{ctx | scopes: []})
  end

  test "tools/call: text, structured, validation error, unknown tool, exception" do
    assert {:reply, r} = call("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}})
    assert r["content"] == [%{"type" => "text", "text" => "hi"}]
    assert r["isError"] == false and r["resultType"] == "complete"

    assert {:reply, r} =
             call("tools/call", %{"name" => "add", "arguments" => %{"a" => 1, "b" => 2}})

    assert r["structuredContent"] == %{"sum" => 3}
    assert [%{"type" => "text", "text" => text}] = r["content"]
    assert JSON.decode!(text) == %{"sum" => 3}

    assert {:reply, r} = call("tools/call", %{"name" => "add", "arguments" => %{"a" => "x"}})
    assert r["isError"] == true
    assert hd(r["content"])["text"] =~ "a: must be a number"
    assert hd(r["content"])["text"] =~ "b: is required"

    assert {:error, %{"code" => -32_602, "message" => "Unknown tool: nope"}} =
             call("tools/call", %{"name" => "nope"})

    assert {:error, %{"code" => -32_602}} = call("tools/call", %{})

    defmodule Boom do
      use Sake.Tool, name: "boom", description: "raises"
      def execute(_, _), do: raise("kaboom")
    end

    defmodule BoomServer do
      use Sake.Server, name: "b", version: "1"
      tools [Boom]
    end

    assert {:reply, r} =
             Dispatch.handle(
               BoomServer,
               {:request, 1, "tools/call", %{"name" => "boom", "arguments" => %{}}},
               ctx(server: BoomServer)
             )

    assert r["isError"] == true and hd(r["content"])["text"] == "The tool failed."

    assert_raise RuntimeError, "kaboom", fn ->
      Dispatch.handle(
        BoomServer,
        {:request, 1, "tools/call", %{"name" => "boom", "arguments" => %{}}},
        ctx(server: BoomServer, reraise: true)
      )
    end
  end

  test "tools/call with content list, meta and error tuple" do
    defmodule Rich do
      use Sake.Tool, name: "rich", description: "content"

      def execute(%{}, _),
        do:
          {:ok, [Sake.Content.text("a"), Sake.Content.resource_link("issue://1")],
           meta: %{"k" => 1}}
    end

    defmodule Fail do
      use Sake.Tool, name: "fail", description: "fails"
      def execute(%{}, _), do: {:error, "bad input"}
    end

    defmodule S do
      use Sake.Server, name: "s", version: "1"
      tools [Rich, Fail]
    end

    assert {:reply, r} =
             Dispatch.handle(
               S,
               {:request, 1, "tools/call", %{"name" => "rich", "arguments" => %{}}},
               ctx(server: S)
             )

    assert [%{"type" => "text"}, %{"type" => "resource_link"}] = r["content"]
    assert r["_meta"]["k"] == 1 and r["_meta"]["io.modelcontextprotocol/serverInfo"]

    assert {:reply, %{"isError" => true, "content" => [%{"text" => "bad input"}]}} =
             Dispatch.handle(
               S,
               {:request, 1, "tools/call", %{"name" => "fail", "arguments" => %{}}},
               ctx(server: S)
             )
  end

  test "resources" do
    assert {:reply, r} = call("resources/list")
    assert Enum.map(r["resources"], & &1["uri"]) == ["dev://readme", "issue://1", "issue://2"]
    assert Enum.at(r["resources"], 1)["name"] == "Login fails on Safari"

    assert {:reply, %{"resourceTemplates" => [%{"uriTemplate" => "issue://{id}"}]}} =
             call("resources/templates/list")

    assert {:reply, r} = call("resources/read", %{"uri" => "issue://1"})

    assert [%{"uri" => "issue://1", "mimeType" => "application/json", "text" => text}] =
             r["contents"]

    assert JSON.decode!(text)["id"] == "1"
    assert r["ttlMs"] == 300_000

    assert {:reply, %{"contents" => [%{"text" => "# sake-dev" <> _}]}} =
             call("resources/read", %{"uri" => "dev://readme"})

    assert {:error, %{"code" => -32_602, "message" => "Resource not found: issue://9"}} =
             call("resources/read", %{"uri" => "issue://9"})

    assert {:error, %{"code" => -32_602}} = call("resources/read", %{"uri" => "x://y"})
  end

  test "prompts and completion" do
    assert {:reply, %{"prompts" => [%{"name" => "triage", "arguments" => [_, _]}]}} =
             call("prompts/list")

    assert {:reply, r} = call("prompts/get", %{"name" => "triage", "arguments" => %{"id" => "1"}})
    assert r["description"] == "Triage of issue 1"

    assert r["messages"] == [
             %{
               "role" => "user",
               "content" => %{"type" => "text", "text" => "Triage issue 1 in a kind tone."}
             }
           ]

    assert {:error, %{"code" => -32_602, "message" => "Missing prompt argument: id"}} =
             call("prompts/get", %{"name" => "triage", "arguments" => %{}})

    assert {:reply, %{"completion" => %{"values" => ["direct"], "hasMore" => false}}} =
             call("completion/complete", %{
               "ref" => %{"type" => "ref/prompt", "name" => "triage"},
               "argument" => %{"name" => "tone", "value" => "d"}
             })

    assert {:reply, %{"completion" => %{"values" => ["1"]}}} =
             call("completion/complete", %{
               "ref" => %{"type" => "ref/resource", "uri" => "issue://{id}"},
               "argument" => %{"name" => "id", "value" => "1"}
             })
  end

  test "unknown method, notifications, and subscriptions/listen" do
    assert {:error, %{"code" => -32_601}} = call("nope")

    assert :noreply =
             Dispatch.handle(
               SakeDev.Server,
               {:notification, "notifications/cancelled", %{}},
               ctx()
             )

    assert {:listen, %{"toolsListChanged" => true}} =
             call("subscriptions/listen", %{"notifications" => %{"toolsListChanged" => true}})
  end
end
