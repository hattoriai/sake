defmodule Sake.UI.NamesTest do
  # An MCP App's own calls (a tool call, a resource read the document
  # makes through the host) use the names the client knows: the document
  # gets them from `Sake.UI.names/2`, under every prefix between the app's
  # server and the one the client reached.
  use ExUnit.Case, async: true

  import Sake.Test

  alias Sake.Client.ToolResult

  # ---- a library's server: an app, the tool it calls, a resource it reads

  defmodule Lookup do
    use Sake.Tool, name: "lookup", description: "Looks a thing up", visibility: [:app]

    arg :id, :string, required: true

    @impl true
    def execute(%{id: id}, ctx), do: {:ok, "thing #{id} from #{inspect(ctx.server)}"}
  end

  defmodule Thing do
    use Sake.Resource, uri: "thing://{id}", name: "thing"

    @impl true
    def read(%{id: id}, _ctx), do: {:ok, "thing #{id}"}
  end

  defmodule Panel do
    use Sake.UI, uri: "ui://things/panel", name: "panel"

    @impl true
    def render(ctx) do
      names = Sake.UI.names(ctx, tools: [Lookup], resources: [Thing, "ui://things/panel"])
      {:safe, tag} = Sake.UI.json_script("names", names)
      ["<!doctype html><p>Things</p>", tag]
    end
  end

  defmodule ShowPanel do
    use Sake.Tool, name: "show_panel", description: "Shows the panel", ui: Panel

    @impl true
    def execute(_args, _ctx), do: {:ok, "shown"}
  end

  defmodule Things do
    use Sake.Server, name: "things", version: "1"
    scope "things:read", "Read things"
    tools [ShowPanel, Lookup]
    resources [Panel, Thing]
  end

  defmodule Scoped do
    use Sake.Server, name: "scoped", version: "1"
    mount Things, prefix: "lib", scope: "things:read"
  end

  # ---- hosts that mount it

  defmodule Host do
    use Sake.Server, name: "host", version: "1"
    mount Things, prefix: "lib"
  end

  defmodule Middle do
    use Sake.Server, name: "middle", version: "1"
    mount Things, prefix: "inner"
  end

  defmodule Nested do
    use Sake.Server, name: "nested", version: "1"
    mount Middle, prefix: "outer"
  end

  defmodule Twice do
    use Sake.Server, name: "twice", version: "1"
    mount Things, prefix: "one"
    mount Things, prefix: "two"
  end

  defmodule HideLookup do
    @moduledoc false
    def call(%{kind: :tools, items: items} = payload, _opts),
      do: {:cont, %{payload | items: Enum.reject(items, &(&1.name == "lib_lookup"))}}

    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule Hiding do
    use Sake.Server, name: "hiding", version: "1"
    mount Things, prefix: "lib"
    middleware :after_list, [HideLookup]
  end

  defmodule DevHost do
    use Sake.Server, name: "dev-host", version: "1"
    mount SakeDev.Server, prefix: "dev"
  end

  # The names the document was rendered with, as its script reads them.
  defp names(client, uri, id \\ "names") do
    {:ok, [%Sake.Content{text: html}]} = read_resource(client, uri)

    [json] =
      Regex.run(~r/<script type="application\/json" id="#{id}">(.*?)<\/script>/s, html,
        capture: :all_but_first
      )

    JSON.decode!(json)
  end

  # What the document does with them: call its tool, read its resource.
  defp act(client, names) do
    {:ok, result} = call_tool(client, names["tools"]["lookup"], %{"id" => "7"})
    uri = String.replace(names["resources"]["thing://{id}"], "{id}", "7")
    {:ok, [%Sake.Content{text: text}]} = read_resource(client, uri)
    {result, text}
  end

  test "served directly, the app's names are its server's own" do
    client = connect(Things, ui: true)
    names = names(client, "ui://things/panel")

    assert names == %{
             "tools" => %{"lookup" => "lookup"},
             "resources" => %{
               "thing://{id}" => "thing://{id}",
               "ui://things/panel" => "ui://things/panel"
             }
           }

    assert {%ToolResult{text: "thing 7 from Sake.UI.NamesTest.Things"}, "thing 7"} =
             act(client, names)
  end

  test "under a prefix, the app calls and reads by the prefixed names" do
    client = connect(Host, ui: true)
    names = names(client, "ui://lib/things/panel")

    assert names["tools"] == %{"lookup" => "lib_lookup"}
    assert names["resources"]["thing://{id}"] == "thing://lib/{id}"
    assert names["resources"]["ui://things/panel"] == "ui://lib/things/panel"

    assert {%ToolResult{text: "thing 7 from Sake.UI.NamesTest.Things"}, "thing 7"} =
             act(client, names)

    # The unprefixed name is not the host's: it is not looked up anywhere.
    assert {:error, {:rpc, %{"code" => -32_602}}} = call_tool(client, "lookup", %{"id" => "7"})
  end

  test "through nested mounts, every prefix is applied, innermost first" do
    client = connect(Nested, ui: true)
    names = names(client, "ui://outer/inner/things/panel")

    assert names["tools"] == %{"lookup" => "outer_inner_lookup"}
    assert names["resources"]["thing://{id}"] == "thing://outer/inner/{id}"
    assert {%ToolResult{is_error: false}, "thing 7"} = act(client, names)
  end

  test "a server mounted twice renders each copy with its own names" do
    client = connect(Twice, ui: true)
    one = names(client, "ui://one/things/panel")
    two = names(client, "ui://two/things/panel")

    assert one["tools"] == %{"lookup" => "one_lookup"}
    assert two["tools"] == %{"lookup" => "two_lookup"}
    assert {%ToolResult{is_error: false}, "thing 7"} = act(client, one)
    assert {%ToolResult{is_error: false}, "thing 7"} = act(client, two)
  end

  test "the resolved name goes through the scopes, the app-only visibility and the middleware" do
    names = names(connect(Scoped, ui: true), "ui://lib/things/panel")

    assert {:error, {:insufficient_scope, %{scope: ["things:read"]}}} =
             call_tool(connect(Scoped, ui: true, scopes: []), names["tools"]["lookup"], %{
               "id" => "1"
             })

    assert {:ok, %ToolResult{is_error: false}} =
             call_tool(
               connect(Scoped, ui: true, scopes: ["things:read"]),
               names["tools"]["lookup"],
               %{"id" => "1"}
             )

    # An app-only tool does not exist for a client without apps.
    assert {:error, {:rpc, %{"code" => -32_602}}} =
             call_tool(connect(Host), "lib_lookup", %{"id" => "1"})

    # A tool the host's :after_list plugs hide stays hidden by its prefixed name.
    hiding = connect(Hiding, ui: true)
    names = names(hiding, "ui://lib/things/panel")

    assert {:error, {:rpc, %{"code" => -32_602}}} =
             call_tool(hiding, names["tools"]["lookup"], %{"id" => "1"})
  end

  test "the issue board's detail action reaches issue_details through a prefixed mount" do
    client = connect(DevHost, ui: true)
    names = names(client, "ui://dev/sake-dev/issue-board", "sake-names")

    assert names["tools"] == %{"issue_details" => "dev_issue_details"}

    assert {:ok, %ToolResult{structured: %{"id" => "1"}}} =
             call_tool(client, names["tools"]["issue_details"], %{"id" => "1"})
  end

  describe "tool_name/2, resource_uri/2 and json_script/2" do
    test "resolve from the context's prefixes" do
      ctx = %Sake.Context{server: Things, prefixes: ["inner", nil, "outer"]}
      assert Sake.UI.tool_name(ctx, Lookup) == "outer_inner_lookup"
      assert Sake.UI.tool_name(ctx, "show_panel") == "outer_inner_show_panel"
      assert Sake.UI.resource_uri(ctx, Thing) == "thing://outer/inner/{id}"
      assert Sake.UI.tool_name(%Sake.Context{server: Things}, Lookup) == "lookup"
    end

    test "refuse a tool or resource the app's server does not have" do
      ctx = %Sake.Context{server: Things, prefixes: ["lib"]}
      assert_raise ArgumentError, ~r/has no tool "nope"/, fn -> Sake.UI.tool_name(ctx, "nope") end

      assert_raise ArgumentError, ~r/has no resource/, fn ->
        Sake.UI.resource_uri(ctx, "x://y")
      end
    end

    test "json_script/2 keeps every value inside its element" do
      {:safe, iodata} = Sake.UI.json_script("n\"x", %{"a" => "</script><!-- & \u2028"})
      html = IO.iodata_to_binary(iodata)

      assert html ==
               ~s(<script type="application/json" id="n&quot;x">) <>
                 ~s({"a":"\\u003c/script\\u003e\\u003c!-- \\u0026 \\u2028"}</script>)

      [json] = Regex.run(~r/">(.*)<\/script>$/, html, capture: :all_but_first)
      assert JSON.decode!(json) == %{"a" => "</script><!-- & \u2028"}
    end
  end
end
