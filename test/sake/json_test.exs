defmodule Sake.JSONTest do
  # Flips `config :sake, :json_library` for the whole node.
  use ExUnit.Case, async: false

  import Sake.Test

  alias Sake.Client
  alias SakeTest.{HTTP, LegacyClient, ModernClient}
  alias SakeTest.JasonPoint, as: Point

  defmodule Place do
    use Sake.Tool, name: "place", description: "Returns a point"
    arg :point, :any

    @impl true
    def execute(args, _ctx), do: {:ok, %{"point" => args[:point] || %Point{x: 1, y: 2}}}
  end

  defmodule Later do
    use Sake.Tool, name: "later", description: "Returns a point, as a task", task: :optional

    @impl true
    def execute(_args, _ctx), do: {:ok, %{"point" => %Point{x: 5, y: 6}}}
  end

  defmodule Origin do
    use Sake.Resource, uri: "point://origin", name: "origin"

    @impl true
    def read(_params, _ctx), do: {:ok, %{"point" => %Point{x: 0, y: 0}}}
  end

  defmodule Server do
    use Sake.Server, name: "points", version: "1"
    tools [Place, Later]
    resources [Origin]
  end

  defmodule Router do
    use Plug.Router
    plug :match
    plug :dispatch

    forward "/mcp",
      to: Sake.Plug,
      init_opts: [server: Sake.JSONTest.Server, secret: String.duplicate("s", 64)]
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:sake, :json_library)
      Sake.JSON.configure!()
    end)
  end

  defp use_jason do
    Application.put_env(:sake, :json_library, Jason)
    Sake.JSON.configure!()
  end

  defp opts, do: ModernClient.opts(server: Server)

  describe "with config :sake, :json_library, Jason" do
    setup do
      use_jason()
      :ok
    end

    test "a tool's struct becomes structuredContent and its JSON text, on the modern era" do
      conn = ModernClient.post(opts(), "tools/call", %{"name" => "place", "arguments" => %{}})
      assert %{"result" => result} = LegacyClient.json(conn)
      assert result["structuredContent"] == %{"point" => %{"x" => 1, "y" => 2}}
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert JSON.decode!(text) == result["structuredContent"]
    end

    test "a tool's struct becomes structuredContent on the legacy era" do
      session = LegacyClient.initialize(opts(), "2025-11-25")

      conn =
        LegacyClient.post(opts(), session, "tools/call", %{"name" => "place", "arguments" => %{}})

      assert %{"result" => %{"structuredContent" => %{"point" => %{"x" => 1, "y" => 2}}}} =
               LegacyClient.json(conn)
    end

    test "a resource's struct is its JSON contents" do
      conn = ModernClient.post(opts(), "resources/read", %{"uri" => "point://origin"})

      assert %{"result" => %{"contents" => [%{"text" => text}]}} = LegacyClient.json(conn)
      assert JSON.decode!(text) == %{"point" => %{"x" => 0, "y" => 0}}
    end

    test "through Sake.Test, and as a task's result" do
      client = connect(Server)

      assert {:ok, %{structured: %{"point" => %{"x" => 1, "y" => 2}}}} =
               call_tool(client, "place")

      assert {:ok, {:task, %{"taskId" => id}}} = call_tool_async(client, "later")

      assert {:ok, %{"status" => "completed", "result" => result}} = await_task(client, id)
      assert result["structuredContent"] == %{"point" => %{"x" => 5, "y" => 6}}
    end

    test "Sake.Client sends a struct in the arguments, on both eras" do
      url = HTTP.start(Router) <> "/mcp"

      for era <- [:modern, :legacy] do
        assert {:ok, session} = Client.connect(url, era: era)

        assert {:ok, result, _session} =
                 Client.call_tool(session, "place", %{"point" => %Point{x: 3, y: 4}})

        assert result.structured == %{"point" => %{"x" => 3, "y" => 4}}
      end
    end
  end

  describe "with the default, Elixir's JSON" do
    test "a struct that only derives Jason.Encoder fails with a hint at the setting" do
      error =
        assert_raise Protocol.UndefinedError, fn ->
          call_tool(connect(Server), "place")
        end

      assert error.protocol == JSON.Encoder

      assert Exception.message(error) =~
               "Sake encoded it with JSON, set by config :sake, :json_library"
    end

    test "the same struct under Jason encodes, and JSON's own structs still do" do
      assert_raise Protocol.UndefinedError, fn -> Sake.JSON.encode!(%Point{x: 1, y: 2}) end
      assert Sake.JSON.encode!(%{"at" => ~D[2026-01-02]}) == ~s({"at":"2026-01-02"})

      use_jason()
      assert JSON.decode!(Sake.JSON.encode!(%Point{x: 1, y: 2})) == %{"x" => 1, "y" => 2}
      assert Sake.JSON.library() == Jason
    end
  end

  test "the setting is checked when it is read" do
    Application.put_env(:sake, :json_library, NoSuchJSON)

    assert_raise ArgumentError,
                 ~r/:json_library must be a module.*NoSuchJSON/,
                 &Sake.JSON.configure!/0

    Application.put_env(:sake, :json_library, String)
    assert_raise ArgumentError, ~r/encode!\/1 and encode_to_iodata!\/1/, &Sake.JSON.configure!/0
  end
end
