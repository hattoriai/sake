defmodule Sake.Server.MountTest do
  use ExUnit.Case, async: true

  import Sake.Test

  alias Sake.Client.ToolResult
  alias SakeTest.Pipe

  # ---- a billing context, a support context, and the app that mounts both

  defmodule Recorder do
    @moduledoc false
    # Tells the test which server's plug saw which event, for which
    # component, by the name that server knows it by.
    @behaviour Sake.Middleware

    @impl true
    def init(name), do: name

    @impl true
    def call(%{ctx: %{scope: %{test: pid}}} = payload, name) do
      send(pid, {:plug, name, payload.server, component(payload)})
      {:cont, payload}
    end

    def call(payload, _name), do: {:cont, payload}

    defp component(%{tool: tool}), do: tool.name
    defp component(%{prompt: prompt}), do: prompt.name
    defp component(%{resource: _, uri: uri}), do: uri
    defp component(%{items: items}), do: Enum.map(items, &(Map.get(&1, :name) || &1.uri))
    defp component(_payload), do: nil
  end

  defmodule HideDraft do
    @moduledoc false
    # The billing context hides its draft tool from a principal without
    # `drafts: true`, by the name it gave the tool.
    def call(%{items: items, ctx: %{scope: scope}} = payload, _opts) do
      if is_map(scope) and scope[:drafts],
        do: {:cont, payload},
        else: {:cont, %{payload | items: Enum.reject(items, &(&1.name == "draft_invoice"))}}
    end
  end

  defmodule Tag do
    @moduledoc false
    # Appends the server's tag to a tool's text, so the test sees the
    # order in which the `after_call` plugs ran.
    def init(tag), do: tag

    def call(%{result: %{"content" => [%{"text" => text} = c | rest]} = result} = payload, tag),
      do:
        {:cont,
         %{payload | result: %{result | "content" => [%{c | "text" => text <> tag} | rest]}}}

    def call(payload, _tag), do: {:cont, payload}
  end

  defmodule Board do
    use Sake.UI, uri: "ui://board", name: "board"

    @impl true
    def render(_ctx), do: "<!doctype html><p>board</p>"
  end

  defmodule CreateInvoice do
    use Sake.Tool, name: "create_invoice", description: "Creates an invoice"
    arg :amount, :integer, required: true

    @impl true
    def execute(%{amount: amount}, _ctx) do
      {:ok,
       [
         Sake.Content.text("Invoice 7 for #{amount}"),
         Sake.Content.resource_link("invoice://7", name: "invoice"),
         Sake.Content.resource_link("https://example.com/pay/7", name: "pay")
       ]}
    end
  end

  defmodule DraftInvoice do
    use Sake.Tool, name: "draft_invoice", description: "Drafts an invoice"

    @impl true
    def execute(_args, _ctx), do: {:ok, "drafted"}
  end

  defmodule ShowBoard do
    use Sake.Tool,
      name: "show_board",
      description: "Shows the board",
      ui: Sake.Server.MountTest.Board

    @impl true
    def execute(_args, _ctx), do: {:ok, "board"}
  end

  defmodule Whoami do
    use Sake.Tool, name: "whoami", description: "Says which server it belongs to"

    @impl true
    def execute(_args, ctx), do: {:ok, inspect(ctx.server)}
  end

  defmodule Touch do
    use Sake.Tool, name: "touch", description: "Announces a change of invoice 1"

    @impl true
    def execute(_args, ctx) do
      Sake.Server.resource_updated(ctx.server, "invoice://1")
      Sake.Server.notify_list_changed(ctx.server, :tools)
      {:ok, "touched"}
    end
  end

  defmodule Export do
    use Sake.Tool, name: "export", description: "Exports, as a task", task: :optional

    @impl true
    def execute(_args, ctx), do: {:ok, "exported by #{inspect(ctx.server)}"}
  end

  defmodule Invoice do
    use Sake.Resource, uri: "invoice://{id}", name: "invoice", subscribe: true

    @impl true
    def read(%{id: id}, _ctx), do: {:ok, "invoice #{id}"}

    @impl true
    def list(_ctx), do: ["invoice://1", %{uri: "invoice://2", name: "second"}]

    @impl true
    def complete("id", partial, _ctx),
      do: {:ok, Enum.filter(["1", "2", "12"], &String.starts_with?(&1, partial))}
  end

  defmodule Terms do
    use Sake.Resource, uri: "billing://terms", name: "terms", mime_type: "text/plain"

    @impl true
    def read(_params, _ctx), do: {:ok, "Pay within 30 days."}
  end

  defmodule Remind do
    use Sake.Prompt, name: "remind", description: "Reminds a customer"
    arg :customer, :string, required: true

    @impl true
    def get(%{customer: customer}, _ctx), do: {:ok, [user: "Remind #{customer}"]}

    @impl true
    def complete("customer", _partial, _ctx), do: {:ok, ["acme"]}
  end

  defmodule Billing do
    use Sake.Server,
      name: "billing",
      version: "1",
      instructions: "Use create_invoice to bill a customer.",
      ttl: 60_000,
      extensions: %{"example/billing" => %{"v" => 1}, "example/shared" => %{"from" => "billing"}}

    scope "billing:write", "Bill customers"

    tools [CreateInvoice, DraftInvoice, ShowBoard, Whoami, Touch, Export]
    resources [Invoice, Terms, Board]
    prompts [Remind]

    middleware :after_list, [HideDraft, {Recorder, :billing}]
    middleware :before_call, [{Recorder, :billing}]
    middleware :after_call, [{Recorder, :billing}, {Tag, " [billing]"}]
    middleware :before_read, [{Recorder, :billing}]
    middleware :before_get, [{Recorder, :billing}]
    middleware :before_request, [{Recorder, :billing}]
  end

  defmodule OpenTicket do
    use Sake.Tool, name: "create_invoice", description: "Support's own create_invoice"

    @impl true
    def execute(_args, _ctx), do: {:ok, "ticket"}
  end

  defmodule Support do
    use Sake.Server, name: "support", version: "1", instructions: "Tickets."
    tools [OpenTicket]
  end

  defmodule App do
    use Sake.Server,
      name: "app",
      version: "1",
      instructions: "The whole app.",
      extensions: %{"example/shared" => %{"from" => "app"}}

    tools [SakeDev.Tools.Echo]
    mount Billing, prefix: "billing"
    mount Support, prefix: "support", scope: "support"

    middleware :before_call, [{Recorder, :app}]
    middleware :after_call, [{Tag, " [app]"}]
    middleware :after_list, [{Recorder, :app}]
  end

  defmodule Outer do
    use Sake.Server, name: "outer", version: "1"
    mount App, prefix: "app"
  end

  defmodule Flat do
    use Sake.Server, name: "flat", version: "1"
    mount Support
  end

  defp scope(extra \\ []), do: Map.new([test: self()] ++ extra)
  defp names(list), do: Enum.map(list, &(Map.get(&1, :name) || &1["name"]))

  describe "names and URIs" do
    for era <- [:modern, :legacy] do
      test "take the prefix (#{era})" do
        client = connect(App, era: unquote(era), scope: scope(drafts: true), ui: true)

        assert {:ok, tools} = list_tools(client)

        assert names(tools) == [
                 "echo",
                 "billing_create_invoice",
                 "billing_draft_invoice",
                 "billing_show_board",
                 "billing_whoami",
                 "billing_touch",
                 "billing_export",
                 "support_create_invoice"
               ]

        board = Enum.find(tools, &(&1.name == "billing_show_board"))
        assert board.ui == "ui://billing/board"
        assert board.meta["ui"]["resourceUri"] == "ui://billing/board"

        assert {:ok, resources} = list_resources(client)

        assert Enum.map(resources, & &1["uri"]) == [
                 "invoice://billing/1",
                 "invoice://billing/2",
                 "billing://billing/terms",
                 "ui://billing/board"
               ]

        assert {:ok, [%{"uriTemplate" => "invoice://billing/{id}"}]} =
                 list_resource_templates(client)

        assert {:ok, [%{"name" => "billing_remind"}]} = list_prompts(client)
      end

      test "calls, reads, prompts and completions reach the mounted components (#{era})" do
        client = connect(App, era: unquote(era), scope: scope(), ui: true)

        assert {:ok, %ToolResult{text: "Invoice 7 for 5 [billing] [app]"} = result} =
                 call_tool(client, "billing_create_invoice", %{"amount" => 5})

        # A link to one of the mounted server's resources takes the prefix;
        # a link elsewhere does not.
        assert [_, %{uri: "invoice://billing/7"}, %{uri: "https://example.com/pay/7"}] =
                 result.content

        assert {:ok, %ToolResult{text: "ticket [app]"}} =
                 call_tool(client, "support_create_invoice", %{})

        assert {:ok, [%Sake.Content{uri: "invoice://billing/3", text: "invoice 3"}]} =
                 read_resource(client, "invoice://billing/3")

        assert {:ok, [%Sake.Content{uri: "billing://billing/terms"}]} =
                 read_resource(client, "billing://billing/terms")

        assert {:ok, [%Sake.Content{uri: "ui://billing/board"}]} =
                 read_resource(client, "ui://billing/board")

        assert {:ok, %{"messages" => [%{"content" => %{"text" => "Remind acme"}}]}} =
                 get_prompt(client, "billing_remind", %{"customer" => "acme"})

        assert {:ok, %{"values" => ["acme"]}} =
                 complete(client, {:prompt, "billing_remind"}, "customer", "a")

        assert {:ok, %{"values" => ["1", "12"]}} =
                 complete(client, {:resource, "invoice://billing/{id}"}, "id", "1")

        # The names the mounted server gave are not the app's.
        assert {:error, {:rpc, %{"code" => -32_602}}} = call_tool(client, "create_invoice", %{})
        assert {:error, {:rpc, _}} = read_resource(client, "invoice://3")
        assert {:error, {:rpc, %{"code" => -32_602}}} = get_prompt(client, "remind", %{})
      end
    end

    test "nest: a server mounted in a mounted server takes both prefixes" do
      client = connect(Outer, scope: scope(), ui: true)

      assert {:ok, tools} = list_tools(client)
      assert "app_billing_create_invoice" in names(tools)

      assert Enum.find(tools, &(&1.name == "app_billing_show_board")).ui ==
               "ui://app/billing/board"

      assert {:ok, %ToolResult{text: "Invoice 7 for 1 [billing] [app]"} = result} =
               call_tool(client, "app_billing_create_invoice", %{"amount" => 1})

      assert %{uri: "invoice://app/billing/7"} = Enum.at(result.content, 1)

      assert {:ok, [%Sake.Content{uri: "invoice://app/billing/2"}]} =
               read_resource(client, "invoice://app/billing/2")

      assert {:ok, resources} = list_resources(client)
      assert "invoice://app/billing/1" in Enum.map(resources, & &1["uri"])
    end

    test "without a prefix, the mounted server's names are the parent's" do
      client = connect(Flat)
      assert {:ok, [%{name: "create_invoice"}]} = list_tools(client)
      assert {:ok, %ToolResult{text: "ticket"}} = call_tool(client, "create_invoice", %{})
    end

    test "the spec keeps the one the mounted server declared" do
      assert {:ok, spec} = Sake.Server.tool(Outer, "app_billing_create_invoice")
      assert {App, "app", %{name: "billing_create_invoice"} = middle} = spec.mount
      assert {Billing, "billing", %{name: "create_invoice", mount: nil}} = middle.mount
      assert Sake.Server.Mount.innermost(spec).name == "create_invoice"
    end
  end

  describe "the server's description" do
    test "instructions, capabilities, extensions and scopes merge" do
      assert App.__sake__(:instructions) ==
               "The whole app.\n\n## billing\n\nUse create_invoice to bill a customer.\n\n## support\n\nTickets."

      assert App.__sake__(:scopes) == [
               {"billing:write", "Bill customers"},
               {"support", "support"}
             ]

      # The app's own extension settings win over a mounted server's.
      assert App.__sake__(:extensions) == %{
               "example/billing" => %{"v" => 1},
               "example/shared" => %{"from" => "app"}
             }

      client = connect(App)
      session = session(client)
      assert session.instructions =~ "## billing"
      caps = session.server_capabilities
      assert caps["resources"]["subscribe"] == true
      assert caps["prompts"] && caps["completions"]
      assert Map.has_key?(caps["extensions"], "example/billing")
      assert Map.has_key?(caps["extensions"], "io.modelcontextprotocol/ui")
      assert Map.has_key?(caps["extensions"], "io.modelcontextprotocol/tasks")

      legacy = session(connect(App, era: :legacy))
      assert legacy.instructions =~ "## support\n\nTickets."
    end

    test "a mounted server's ttl bounds its components" do
      {:ok, spec} = Sake.Server.tool(App, "billing_whoami")
      assert spec.ttl == 60_000
      {:ok, own} = Sake.Server.tool(App, "echo")
      assert own.ttl == nil
    end

    test "the mount's scope gates every component it mounts" do
      client = connect(App, scope: scope(), scopes: [])

      assert {:ok, tools} = list_tools(client)
      refute "support_create_invoice" in names(tools)
      assert "billing_whoami" in names(tools)

      assert {:error, {:insufficient_scope, %{scope: ["support"]}}} =
               call_tool(client, "support_create_invoice", %{})

      client = connect(App, scope: scope(), scopes: ["support"])

      assert {:ok, %ToolResult{text: "ticket [app]"}} =
               call_tool(client, "support_create_invoice", %{})
    end
  end

  describe "middleware" do
    test "the parent's runs around every component, the mounted server's around its own" do
      client = connect(App, scope: scope())

      assert {:ok, %ToolResult{text: "hi [app]"}} = call_tool(client, "echo", %{"text" => "hi"})
      assert_received {:plug, :app, App, "echo"}
      refute_received {:plug, :billing, _, _}

      assert {:ok, _} = call_tool(client, "billing_whoami", %{})

      # The app's before_call first, then billing's, which sees the name
      # billing gave the tool; billing's after_call before the app's (the
      # tags above read " [billing] [app]").
      assert_received {:plug, :app, App, "billing_whoami"}
      assert_received {:plug, :billing, Billing, "whoami"}

      # A mounted server's before_request does not run: the request is the
      # app's.
      refute_received {:plug, :billing, _, nil}
    end

    test "the plugs run outermost first before a call, innermost first after it" do
      client = connect(App, scope: scope())
      assert {:ok, _} = call_tool(client, "billing_whoami", %{})

      {:messages, messages} = Process.info(self(), :messages)

      order =
        for {:plug, name, _server, tool} <- messages,
            tool in ["billing_whoami", "whoami"],
            do: {name, tool}

      # before_call: app, then billing; after_call: billing (the app has
      # no recorder there).
      assert order == [{:app, "billing_whoami"}, {:billing, "whoami"}, {:billing, "whoami"}]
    end

    test "a mounted server's after_list hides its component from the parent's list and calls" do
      client = connect(App, scope: scope())
      assert {:ok, tools} = list_tools(client)
      refute "billing_draft_invoice" in names(tools)

      # Billing's plug saw its own components by their own names, before
      # the app's plug saw the list.
      assert_received {:plug, :billing, Billing, billing_items}
      assert "create_invoice" in billing_items
      assert_received {:plug, :app, App, app_items}
      assert "billing_create_invoice" in app_items
      refute "billing_draft_invoice" in app_items

      assert {:error,
              {:rpc, %{"code" => -32_602, "message" => "Unknown tool: billing_draft_invoice"}}} =
               call_tool(client, "billing_draft_invoice", %{})

      client = connect(App, scope: scope(drafts: true))

      assert {:ok, %ToolResult{text: "drafted [billing] [app]"}} =
               call_tool(client, "billing_draft_invoice", %{})
    end

    test "read and get plugs see the URI and name as the mounted server knows them" do
      client = connect(App, scope: scope())
      assert {:ok, _} = read_resource(client, "invoice://billing/4")
      assert_received {:plug, :billing, Billing, "invoice://4"}

      assert {:ok, _} = get_prompt(client, "billing_remind", %{"customer" => "x"})
      assert_received {:plug, :billing, Billing, "remind"}
    end
  end

  describe "components" do
    test "see their own server in ctx.server" do
      client = connect(App)

      assert {:ok, %ToolResult{text: "Sake.Server.MountTest.Billing [billing] [app]"}} =
               call_tool(client, "billing_whoami", %{})
    end

    test "a mounted server's broadcasts reach the parent's clients under the prefix" do
      client = connect(Outer)
      listen(client)

      assert {:ok, _} = call_tool(client, "app_billing_touch", %{})
      assert_resource_updated "invoice://app/billing/1"
      assert_list_changed :tools

      Sake.Server.resource_updated(Billing, "invoice://2")
      assert_resource_updated "invoice://app/billing/2"
    end

    test "a mounted task tool runs as a task of the parent" do
      client = connect(App)
      assert {:ok, {:task, task}} = call_tool_async(client, "billing_export", %{})
      assert task["status"] == "working"

      assert {:ok, %{"status" => "completed", "result" => result}} = await_task(client, task)

      assert %{
               "content" => [
                 %{"text" => "exported by Sake.Server.MountTest.Billing [billing] [app]"}
               ]
             } =
               result
    end
  end

  describe "over stdio" do
    setup do
      %{pipe: Pipe.start()}
    end

    test "a legacy session's subscription to a mounted resource follows the mounted server's broadcasts",
         %{pipe: pipe} do
      Task.start_link(fn -> Sake.Stdio.run(App, input: pipe, output: pipe) end)

      Pipe.push(
        pipe,
        Sake.JSONRPC.request(0, "initialize", %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "t", "version" => "1"}
        })
      )

      assert %{"id" => 0} = recv(pipe)
      Pipe.push(pipe, Sake.JSONRPC.notification("notifications/initialized"))

      Pipe.push(
        pipe,
        Sake.JSONRPC.request(1, "resources/subscribe", %{"uri" => "invoice://billing/1"})
      )

      assert %{"id" => 1, "result" => %{}} = recv(pipe)

      Sake.Server.resource_updated(Billing, "invoice://2")
      Sake.Server.resource_updated(Billing, "invoice://1")

      assert %{
               "method" => "notifications/resources/updated",
               "params" => %{"uri" => "invoice://billing/1"}
             } = recv(pipe)
    end

    defp recv(pipe) do
      assert_receive {:pipe, ^pipe, message}, 2_000
      message
    end
  end

  describe "compile-time checks" do
    test "a name listed twice across mounted servers" do
      assert_raise ArgumentError, ~r/tool "create_invoice" is listed twice/, fn ->
        defmodule Twice do
          use Sake.Server, name: "twice", version: "1"
          mount Sake.Server.MountTest.Support
          tools [Sake.Server.MountTest.CreateInvoice]
        end
      end

      assert_raise ArgumentError, ~r/tool "x_create_invoice" is listed twice/, fn ->
        defmodule SamePrefix do
          use Sake.Server, name: "same", version: "1"
          mount Sake.Server.MountTest.Support, prefix: "x"
          mount Sake.Server.MountTest.Billing, prefix: "x"
        end
      end
    end

    test "a bad prefix, option or server" do
      assert_raise ArgumentError, ~r/prefix .* must be/, fn ->
        defmodule BadPrefix do
          use Sake.Server, name: "bad", version: "1"
          mount Sake.Server.MountTest.Support, prefix: "a/b"
        end
      end

      assert_raise ArgumentError, ~r/mount takes prefix: and scope:/, fn ->
        defmodule BadOption do
          use Sake.Server, name: "bad", version: "1"
          mount Sake.Server.MountTest.Support, name: "x"
        end
      end

      assert_raise ArgumentError, ~r/mount needs a Sake.Server/, fn ->
        defmodule NotAServer do
          use Sake.Server, name: "bad", version: "1"
          mount Sake.Server.MountTest.Recorder
        end
      end
    end

    test "a URI with no scheme:// to put the prefix after" do
      assert_raise ArgumentError, ~r/no scheme:\/\//, fn ->
        defmodule Urn do
          use Sake.Resource, uri: "urn:example:thing"

          @impl true
          def read(_params, _ctx), do: {:ok, ""}
        end

        defmodule UrnServer do
          use Sake.Server, name: "urn", version: "1"
          resources [Urn]
        end

        defmodule UrnParent do
          use Sake.Server, name: "urn-parent", version: "1"
          mount UrnServer, prefix: "p"
        end
      end
    end
  end

  describe "prefixes" do
    alias Sake.Server.Mount

    test "names and URIs round-trip" do
      assert Mount.name("b", "x") == "b_x"
      assert Mount.unname("b", "b_x") == {:ok, "x"}
      assert Mount.unname("b", "bx") == :error
      assert Mount.unname("b", "b_") == :error
      assert Mount.uri("b", "file:///etc/x") == {:ok, "file://b//etc/x"}
      assert Mount.unuri("b", "file://b//etc/x") == {:ok, "file:///etc/x"}
      assert Mount.unuri("b", "file://c/x") == :error
      assert Mount.uri("b", "urn:x") == :error
      assert Mount.uri(nil, "urn:x") == {:ok, "urn:x"}
    end
  end
end
