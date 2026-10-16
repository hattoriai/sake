defmodule Sake.Server.UITest do
  use ExUnit.Case, async: true

  import Sake.Test

  alias SakeTest.{LegacyClient, ModernClient}

  @ui "io.modelcontextprotocol/ui"
  @host %{"extensions" => %{@ui => %{"mimeTypes" => ["text/html;profile=mcp-app"]}}}

  defmodule Board do
    use Sake.UI,
      uri: "ui://test/board",
      name: "board",
      title: "Board",
      csp: [connect_domains: ["https://api.example.com"]],
      prefers_border: true

    @impl true
    def render(_ctx), do: "<!doctype html><p>board</p>"
  end

  defmodule Show do
    use Sake.Tool,
      name: "show_board",
      description: "Shows the board",
      ui: Board,
      meta: %{"vendor" => "x"}

    @impl true
    def execute(_args, _ctx), do: {:ok, %{cards: 3}}
  end

  defmodule Move do
    use Sake.Tool,
      name: "move_card",
      description: "Moves a card, from the board",
      ui: Board,
      visibility: [:app]

    arg :card, :integer, required: true

    @impl true
    def execute(%{card: card}, _ctx), do: {:ok, "moved #{card}"}
  end

  defmodule Refresh do
    use Sake.Tool, name: "refresh", visibility: [:app]
    @impl true
    def execute(_args, _ctx), do: {:ok, "refreshed"}
  end

  defmodule Summary do
    use Sake.Tool, name: "summary", visibility: [:model]
    @impl true
    def execute(_args, ctx), do: {:ok, if(Sake.UI.supported?(ctx), do: "host", else: "text")}
  end

  defmodule Export do
    use Sake.Tool, name: "export_board", ui: Board, task: :optional
    @impl true
    def execute(_args, _ctx), do: {:ok, %{exported: true}}
  end

  defmodule Server do
    use Sake.Server, name: "apps", version: "1", extensions: %{"x.y/z" => %{}}
    tools [SakeDev.Tools.Echo, Show, Move, Refresh, Summary, Export]
    resources [SakeDev.Resources.Readme, Board]
  end

  defmodule Plain do
    use Sake.Server, name: "plain", version: "1"
    tools [SakeDev.Tools.Echo]
    resources [SakeDev.Resources.Readme]
  end

  defp opts(server \\ Server), do: ModernClient.opts(server: server)

  defp rpc(opts, method, params, caps) do
    opts |> ModernClient.post(method, params, capabilities: caps) |> ModernClient.json()
  end

  defp names(tools), do: Enum.map(tools, & &1["name"])

  describe "capabilities" do
    test "server/discover and initialize advertise the extension when the server has a UI" do
      assert %{"result" => %{"capabilities" => %{"extensions" => ext}}} =
               rpc(opts(), "server/discover", %{}, %{})

      assert ext == %{
               "x.y/z" => %{},
               "io.modelcontextprotocol/tasks" => %{},
               @ui => %{}
             }

      assert %{"result" => %{"capabilities" => caps}} =
               rpc(opts(Plain), "server/discover", %{}, %{})

      refute Map.has_key?(caps, "extensions")

      for revision <- ["2025-11-25", "2025-06-18", "2025-03-26"] do
        session = LegacyClient.initialize(opts(), revision)
        assert session.result["capabilities"]["extensions"] == %{@ui => %{}}
      end

      session = LegacyClient.initialize(opts(Plain), "2025-11-25")
      refute Map.has_key?(session.result["capabilities"], "extensions")
    end
  end

  describe "a host (the extension declared)" do
    test "tools/list: every tool, with _meta.ui" do
      assert %{"result" => %{"tools" => tools} = r} = rpc(opts(), "tools/list", %{}, @host)

      assert names(tools) == [
               "echo",
               "show_board",
               "move_card",
               "refresh",
               "summary",
               "export_board"
             ]

      by_name = Map.new(tools, &{&1["name"], &1})
      refute Map.has_key?(by_name["echo"], "_meta")

      assert by_name["show_board"]["_meta"] == %{
               "vendor" => "x",
               "ui" => %{"resourceUri" => "ui://test/board", "visibility" => ["model", "app"]},
               "ui/resourceUri" => "ui://test/board"
             }

      assert by_name["move_card"]["_meta"] == %{
               "ui" => %{"resourceUri" => "ui://test/board", "visibility" => ["app"]},
               "ui/resourceUri" => "ui://test/board"
             }

      assert by_name["refresh"]["_meta"] == %{"ui" => %{"visibility" => ["app"]}}
      assert by_name["summary"]["_meta"] == %{"ui" => %{"visibility" => ["model"]}}
      assert by_name["export_board"]["_meta"]["ui"]["resourceUri"] == "ui://test/board"

      # The list depends on the client's capabilities: no shared cache.
      assert r["cacheScope"] == "private"
    end

    test "resources/list lists the UI with its _meta.ui; resources/read carries it too" do
      assert %{"result" => %{"resources" => resources} = r} =
               rpc(opts(), "resources/list", %{}, @host)

      meta = %{
        "ui" => %{
          "csp" => %{"connectDomains" => ["https://api.example.com"]},
          "prefersBorder" => true
        }
      }

      assert [%{"uri" => "dev://readme"}, board] = resources

      assert board == %{
               "uri" => "ui://test/board",
               "name" => "board",
               "title" => "Board",
               "mimeType" => "text/html;profile=mcp-app",
               "_meta" => meta
             }

      assert r["cacheScope"] == "private"

      assert %{"result" => %{"contents" => [content]} = read} =
               rpc(opts(), "resources/read", %{"uri" => "ui://test/board"}, @host)

      assert content == %{
               "uri" => "ui://test/board",
               "mimeType" => "text/html;profile=mcp-app",
               "text" => "<!doctype html><p>board</p>",
               "_meta" => meta
             }

      # The document is the same for every client.
      assert read["cacheScope"] == "public"

      assert %{"result" => %{"contents" => [readme]}} =
               rpc(opts(), "resources/read", %{"uri" => "dev://readme"}, @host)

      refute Map.has_key?(readme, "_meta")
    end

    test "tools/call: the text fallback and structuredContent, and an app-only tool" do
      assert %{"result" => r} =
               rpc(opts(), "tools/call", %{"name" => "show_board", "arguments" => %{}}, @host)

      assert r["structuredContent"] == %{"cards" => 3}
      assert [%{"type" => "text"}] = r["content"]

      assert %{"result" => %{"content" => [%{"text" => "moved 7"}]}} =
               rpc(
                 opts(),
                 "tools/call",
                 %{"name" => "move_card", "arguments" => %{"card" => 7}},
                 @host
               )

      assert %{"result" => %{"content" => [%{"text" => "host"}]}} =
               rpc(opts(), "tools/call", %{"name" => "summary", "arguments" => %{}}, @host)
    end

    test "a UI tool can run as a task" do
      tasks = Map.update!(@host, "extensions", &Map.put(&1, "io.modelcontextprotocol/tasks", %{}))

      assert %{"result" => %{"resultType" => "task"}} =
               rpc(opts(), "tools/call", %{"name" => "export_board", "arguments" => %{}}, tasks)
    end
  end

  describe "a client without MCP Apps" do
    for caps <- [
          %{},
          %{"extensions" => %{"io.modelcontextprotocol/ui" => %{}}},
          %{"extensions" => %{"io.modelcontextprotocol/ui" => %{"mimeTypes" => ["text/html"]}}}
        ] do
      @caps caps

      test "plain tools, no app-only tools, no UI resources (#{inspect(caps)})" do
        assert %{"result" => %{"tools" => tools} = r} = rpc(opts(), "tools/list", %{}, @caps)
        assert names(tools) == ["echo", "show_board", "summary", "export_board"]
        assert Enum.all?(tools, &(not Map.has_key?(&1["_meta"] || %{}, "ui")))
        assert Enum.find(tools, &(&1["name"] == "show_board"))["_meta"] == %{"vendor" => "x"}
        assert r["cacheScope"] == "private"

        assert %{"result" => %{"resources" => [%{"uri" => "dev://readme"}]}} =
                 rpc(opts(), "resources/list", %{}, @caps)
      end
    end

    test "an app-only tool is an unknown tool; the UI can still be read" do
      for name <- ["move_card", "refresh"] do
        assert %{"error" => %{"code" => -32_602, "message" => "Unknown tool: " <> ^name}} =
                 rpc(opts(), "tools/call", %{"name" => name, "arguments" => %{"card" => 1}}, %{})
      end

      assert %{"result" => %{"content" => [%{"text" => "text"}]}} =
               rpc(opts(), "tools/call", %{"name" => "summary", "arguments" => %{}}, %{})

      assert %{"result" => %{"contents" => [%{"mimeType" => "text/html;profile=mcp-app"}]}} =
               rpc(opts(), "resources/read", %{"uri" => "ui://test/board"}, %{})
    end

    test "a server without a UI keeps its lists public" do
      for method <- ["tools/list", "resources/list"] do
        assert %{"result" => %{"cacheScope" => "public"}} = rpc(opts(Plain), method, %{}, %{})
      end
    end
  end

  describe "legacy" do
    test "a session that declared the extension in initialize is a host" do
      client = connect(Server, era: :legacy, ui: true)
      assert {:ok, tools} = list_tools(client)

      assert %Sake.Tool.Spec{ui: "ui://test/board", visibility: [:app]} =
               Enum.find(tools, &(&1.name == "move_card"))

      assert {:ok, [_, %{"uri" => "ui://test/board", "_meta" => _}]} = list_resources(client)
      assert {:ok, [%Sake.Content{meta: %{"ui" => _}}]} = read_resource(client, "ui://test/board")
      assert {:ok, %{text: "moved 2"}} = call_tool(client, "move_card", %{"card" => 2})
    end

    test "a session without it gets plain tools" do
      client = connect(Server, era: :legacy)
      assert {:ok, tools} = list_tools(client)
      assert Enum.map(tools, & &1.name) == ["echo", "show_board", "summary", "export_board"]
      assert Enum.all?(tools, &(&1.ui == nil))
      assert {:ok, [%{"uri" => "dev://readme"}]} = list_resources(client)

      assert {:error, {:rpc, %{"code" => -32_602}}} =
               call_tool(client, "move_card", %{"card" => 2})
    end
  end

  describe "compile-time checks" do
    test "a tool's UI must be among the server's resources" do
      assert_raise ArgumentError,
                   ~r/tool "show_board" shows the UI "ui:\/\/test\/board", which is not among/,
                   fn ->
                     defmodule Missing do
                       use Sake.Server, name: "missing", version: "1"
                       tools [Show]
                       resources [SakeDev.Resources.Readme]
                     end
                   end
    end

    test "ui: names a Sake.UI and visibility: lists :model and :app" do
      assert_raise ArgumentError, ~r/ui: SakeDev.Resources.Readme is not a Sake.UI/, fn ->
        defmodule NotUI do
          use Sake.Tool, name: "not_ui", ui: SakeDev.Resources.Readme
          def execute(_, _), do: {:ok, ""}
        end
      end

      assert_raise ArgumentError, ~r/ui: Nope.Missing is not a Sake.UI/, fn ->
        defmodule NoModule do
          use Sake.Tool, name: "no_module", ui: Nope.Missing
          def execute(_, _), do: {:ok, ""}
        end
      end

      for visibility <- ["[]", "[:user]", ":app"] do
        assert_raise ArgumentError, ~r/visibility: must list :model, :app or both/, fn ->
          Code.eval_string("""
          defmodule Sake.Server.UITest.BadVisibility do
            use Sake.Tool, name: "bad", visibility: #{visibility}
            def execute(_, _), do: {:ok, ""}
          end
          """)
        end
      end

      assert %Sake.Tool.Spec{ui: "ui://test/board", visibility: [:app]} = Move.spec()
      assert %Sake.Tool.Spec{ui: nil, visibility: [:model, :app]} = SakeDev.Tools.Echo.spec()
    end
  end
end
