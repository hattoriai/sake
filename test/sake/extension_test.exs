defmodule Sake.ExtensionTest do
  # The stdio and proxy tests start named processes and broadcast, so the
  # module runs alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Sake.Test

  alias SakeTest.{HTTP, ModernClient, Pipe}

  @modern "2026-07-28"

  defmodule Widgets do
    use Sake.Extension,
      id: "com.example/widgets",
      scope: "widgets:read",
      result_types: ["widgetJob"]

    method("widgets/list")
    method("widgets/delete", scope: "widgets:write")
    method("widgets/where")
    method("widgets/fail")
    method("widgets/odd")
    method("widgets/job")
    notification("notifications/widgets/changed")

    @impl true
    def settings(server), do: %{"maxPageSize" => 50, "server" => inspect(server)}

    @impl true
    def handle("widgets/list", params, ctx) do
      {:ok,
       Sake.Extension.cacheable(%{"widgets" => ["a", "b"], "cursor" => params["cursor"]}, ctx,
         ttl: 1_000
       )}
    end

    def handle("widgets/delete", %{"id" => id}, ctx) do
      Sake.Extension.notify(ctx.server, __MODULE__, "notifications/widgets/changed", %{
        "deleted" => id
      })

      {:ok, %{}}
    end

    def handle("widgets/delete", _params, _ctx),
      do: {:error, -32_602, "widgets/delete needs an id", %{"field" => "id"}}

    def handle("widgets/where", _params, ctx),
      do: {:ok, %{"server" => inspect(ctx.server), "prefixes" => ctx.prefixes}}

    def handle("widgets/fail", _params, _ctx), do: raise("kaboom")
    def handle("widgets/odd", _params, _ctx), do: :what

    def handle("widgets/job", _params, _ctx),
      do: {:ok, %{"resultType" => "widgetJob", "jobId" => "1"}}
  end

  defmodule Strict do
    use Sake.Extension, id: "com.example/strict", client: :required
    method("strict/ping")

    @impl true
    def handle("strict/ping", _params, _ctx), do: {:ok, %{"pong" => true}}
  end

  defmodule ModernOnly do
    use Sake.Extension, id: "com.example/modern", since: "2026-07-28"
    method("modern/ping")

    @impl true
    def handle("modern/ping", _params, _ctx), do: {:ok, %{}}
  end

  defmodule RefuseFlagged do
    @moduledoc false
    # A :before_request plug sees an extension's method and params.
    def call(%{method: "widgets/" <> _, params: %{"refuse" => true}}, _opts),
      do: {:halt, {:error, "refused"}}

    def call(%{ctx: %{scope: %{test: pid}}, method: method} = payload, _opts) do
      send(pid, {:before_request, method})
      {:cont, payload}
    end

    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule Server do
    use Sake.Server, name: "widgets", version: "1"
    tools [SakeDev.Tools.Echo]
    extensions [Widgets, Strict, ModernOnly]
    middleware :before_request, [RefuseFlagged]
  end

  defp request(client, method, params \\ %{}) do
    case Sake.Client.request(session(client), method, params) do
      {:ok, result, _} -> {:ok, result}
      {:error, reason, _} -> {:error, reason}
    end
  end

  describe "negotiation" do
    test "the server advertises each extension with its settings, on both eras" do
      client = connect(Server)
      caps = session(client).server_capabilities["extensions"]

      assert caps["com.example/widgets"] == %{
               "maxPageSize" => 50,
               "server" => "Sake.ExtensionTest.Server"
             }

      assert caps["com.example/strict"] == %{}
      assert caps["com.example/modern"] == %{}

      legacy = session(connect(Server, era: :legacy)).server_capabilities["extensions"]
      assert legacy["com.example/widgets"]["maxPageSize"] == 50
      refute Map.has_key?(legacy, "com.example/modern")
    end

    test "since: serves an extension from that revision on" do
      assert {:ok, %{}} = request(connect(Server), "modern/ping")

      assert {:error, {:rpc, %{"code" => -32_601}}} =
               request(connect(Server, era: :legacy), "modern/ping")
    end

    test "client: :required refuses a client that did not declare the extension" do
      assert {:error, {:rpc, %{"code" => -32_021, "data" => data}}} =
               request(connect(Server), "strict/ping")

      assert data == %{
               "requiredCapabilities" => %{"extensions" => %{"com.example/strict" => %{}}}
             }

      declared = %{"extensions" => %{"com.example/strict" => %{}}}

      assert %{"result" => %{"pong" => true}} =
               ModernClient.opts(server: Server)
               |> ModernClient.post("strict/ping", %{}, capabilities: declared)
               |> ModernClient.json()
    end

    test "a server without an extension answers its methods as unknown" do
      assert {:error, {:rpc, %{"code" => -32_601}}} =
               request(connect(SakeDev.Server), "widgets/list")
    end
  end

  describe "requests" do
    test "go through the endpoint as core requests: result, resultType, server info, caching" do
      opts = ModernClient.opts(server: Server)
      conn = ModernClient.post(opts, "widgets/list", %{"cursor" => "c1"})

      assert %{
               "result" => %{
                 "widgets" => ["a", "b"],
                 "cursor" => "c1",
                 "resultType" => "complete",
                 "ttlMs" => 1_000,
                 "cacheScope" => "public",
                 "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => "widgets"}}
               }
             } = ModernClient.json(conn)
    end

    test "errors, exceptions and bad returns" do
      client = connect(Server)

      assert {:error,
              {:rpc,
               %{
                 "code" => -32_602,
                 "message" => "widgets/delete needs an id",
                 "data" => %{"field" => "id"}
               }}} =
               request(client, "widgets/delete")

      # Through the HTTP endpoint: Sake.Test re-raises a component's
      # exception, so that a test sees it.
      opts = ModernClient.opts(server: Server)

      log =
        capture_log(fn ->
          assert %{"error" => %{"code" => -32_603, "message" => "The request failed."}} =
                   opts |> ModernClient.post("widgets/fail") |> ModernClient.json()

          assert %{"error" => %{"code" => -32_603}} =
                   opts |> ModernClient.post("widgets/odd") |> ModernClient.json()
        end)

      assert log =~ "extension com.example/widgets failed on widgets/fail"
      assert log =~ "returned :what, not a result"
    end

    test "a result type of the extension's own goes only to a client that negotiated it" do
      opts = ModernClient.opts(server: Server)
      declared = %{"extensions" => %{"com.example/widgets" => %{}}}

      assert %{"result" => %{"resultType" => "widgetJob", "jobId" => "1"}} =
               opts
               |> ModernClient.post("widgets/job", %{}, capabilities: declared)
               |> ModernClient.json()

      capture_log(fn ->
        assert %{"error" => %{"code" => -32_603}} =
                 opts |> ModernClient.post("widgets/job") |> ModernClient.json()
      end)
    end

    test "scopes: a token without the method's scopes is asked to step up" do
      assert {:error, {:insufficient_scope, %{scope: ["widgets:read"]}}} =
               request(connect(Server, scopes: []), "widgets/list")

      assert {:error, {:insufficient_scope, %{scope: ["widgets:read", "widgets:write"]}}} =
               request(connect(Server, scopes: ["widgets:read"]), "widgets/delete", %{"id" => "a"})

      assert {:ok, %{}} =
               request(
                 connect(Server, scopes: ["widgets:read", "widgets:write"]),
                 "widgets/delete",
                 %{"id" => "a"}
               )
    end

    test "the :before_request middleware sees the method and can refuse it" do
      client = connect(Server, scope: %{test: self()})
      assert {:ok, _} = request(client, "widgets/list")
      assert_received {:before_request, "widgets/list"}

      assert {:error, {:rpc, %{"message" => "refused"}}} =
               request(client, "widgets/list", %{"refuse" => true})
    end

    test "over stdio, modern and legacy" do
      pipe = Pipe.start()
      test = self()

      {:ok, _} =
        Task.start_link(fn ->
          Sake.Stdio.run(Server, input: pipe, output: pipe)
          send(test, :stopped)
        end)

      meta = %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }

      Pipe.push(pipe, Sake.JSONRPC.request(1, "widgets/list", %{"_meta" => meta}))

      assert_receive {:pipe, ^pipe,
                      %{
                        "id" => 1,
                        "result" => %{"widgets" => ["a", "b"], "resultType" => "complete"}
                      }},
                     2_000

      Pipe.push(pipe, Sake.JSONRPC.request(2, "nope/nope", %{"_meta" => meta}))
      assert_receive {:pipe, ^pipe, %{"id" => 2, "error" => %{"code" => -32_601}}}, 2_000
    end
  end

  describe "notifications" do
    test "reach a modern listen stream that asked for the extension, over stdio" do
      pipe = Pipe.start()
      {:ok, _} = Task.start_link(fn -> Sake.Stdio.run(Server, input: pipe, output: pipe) end)

      meta = %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }

      Pipe.push(
        pipe,
        Sake.JSONRPC.request(7, "subscriptions/listen", %{
          "_meta" => meta,
          "notifications" => %{"com.example/widgets" => true, "com.example/strict" => true}
        })
      )

      # Strict sends no notification: only widgets is honoured.
      assert_receive {:pipe, ^pipe,
                      %{
                        "method" => "notifications/subscriptions/acknowledged",
                        "params" => %{
                          "notifications" => %{"com.example/widgets" => true} = honoured
                        }
                      }},
                     2_000

      refute Map.has_key?(honoured, "com.example/strict")

      Sake.Extension.notify(Server, Widgets, "notifications/widgets/changed", %{"deleted" => "a"})

      assert_receive {:pipe, ^pipe,
                      %{
                        "method" => "notifications/widgets/changed",
                        "params" => %{
                          "deleted" => "a",
                          "_meta" => %{"io.modelcontextprotocol/subscriptionId" => 7}
                        }
                      }},
                     2_000
    end

    test "reach a legacy stdio session" do
      pipe = Pipe.start()
      {:ok, _} = Task.start_link(fn -> Sake.Stdio.run(Server, input: pipe, output: pipe) end)

      Pipe.push(
        pipe,
        Sake.JSONRPC.request(0, "initialize", %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{}
        })
      )

      assert_receive {:pipe, ^pipe,
                      %{"id" => 0, "result" => %{"capabilities" => %{"extensions" => ext}}}},
                     2_000

      assert Map.has_key?(ext, "com.example/widgets")
      Pipe.push(pipe, Sake.JSONRPC.notification("notifications/initialized"))

      Sake.Extension.notify(Server, "com.example/widgets", "notifications/widgets/changed", %{
        "x" => 1
      })

      assert_receive {:pipe, ^pipe,
                      %{"method" => "notifications/widgets/changed", "params" => %{"x" => 1}}},
                     2_000
    end

    test "notify/4 refuses a notification the extension does not declare, or an extension the server lacks" do
      assert_raise ArgumentError, ~r/declares no notification/, fn ->
        Sake.Extension.notify(Server, Widgets, "notifications/other", %{})
      end

      assert_raise ArgumentError, ~r/serves no extension/, fn ->
        Sake.Extension.notify(SakeDev.Server, Widgets, "notifications/widgets/changed", %{})
      end
    end
  end

  describe "composition" do
    defmodule Library do
      use Sake.Server, name: "library", version: "1"
      extensions [Sake.ExtensionTest.Widgets]
    end

    defmodule Host do
      use Sake.Server, name: "host", version: "1"
      mount Library, prefix: "lib", scope: "lib"
      mount Library, prefix: "again"
    end

    test "a mounted server's extension is the parent's, run as its own server's, with the mount's scope" do
      client = connect(Host)

      assert session(client).server_capabilities["extensions"]["com.example/widgets"]["server"] ==
               "Sake.ExtensionTest.Library"

      # Served once, by the first mount: its prefix, and its scope.
      assert {:ok, %{"server" => "Sake.ExtensionTest.Library", "prefixes" => ["lib"]}} =
               request(client, "widgets/where")

      assert {:error, {:insufficient_scope, %{scope: ["widgets:read", "lib"]}}} =
               request(connect(Host, scopes: ["widgets:read"]), "widgets/where")
    end

    test "collisions are compile errors" do
      for {body, message} <- [
            {~s(use Sake.Extension, id: "com.example/x"\n method "tools/list"),
             "a method of the protocol"},
            {~s(use Sake.Extension, id: "com.example/x"\n method "notifications/x/y"),
             "names a notification"},
            {~s(use Sake.Extension, id: "com.example/x"\n method "widgets/list"),
             "both declare the method"},
            {~s(use Sake.Extension, id: "com.example/widgets"\n method "other/x"),
             "are both the extension"}
          ] do
        n = System.unique_integer([:positive])

        source = """
        defmodule Sake.ExtensionTest.Ext#{n} do
          #{body}
          def handle(_m, _p, _c), do: {:ok, %{}}
        end

        defmodule Sake.ExtensionTest.Srv#{n} do
          use Sake.Server, name: "s", version: "1"
          extensions [Sake.ExtensionTest.Widgets, Sake.ExtensionTest.Ext#{n}]
        end
        """

        error = assert_raise ArgumentError, fn -> Code.compile_string(source) end
        assert error.message =~ message, error.message
      end

      advertised = """
      defmodule Sake.ExtensionTest.Adv#{System.unique_integer([:positive])} do
        use Sake.Server, name: "s", version: "1", extensions: %{"com.example/widgets" => %{}}
        extensions [Sake.ExtensionTest.Widgets]
      end
      """

      assert_raise ArgumentError, ~r/both in extensions: and served by/, fn ->
        Code.compile_string(advertised)
      end
    end

    test "an extension's own definition is checked when it compiles" do
      for {opts, message} <- [
            {~s(id: "widgets"), "vendor-prefix/name"},
            {~s(id: "io.modelcontextprotocol/x"), "the protocol's own"},
            {~s(id: "com.example/x", since: "1999-01-01"), "not a revision"},
            {~s(id: "com.example/x", client: :maybe), "client: must be"},
            {~s(id: "com.example/x", colour: :red), "does not take"}
          ] do
        source = """
        defmodule Sake.ExtensionTest.Bad#{System.unique_integer([:positive])} do
          use Sake.Extension, #{opts}
          method "x/y"
          def handle(_m, _p, _c), do: {:ok, %{}}
        end
        """

        error = assert_raise ArgumentError, fn -> Code.compile_string(source) end
        assert error.message =~ message
      end

      assert_raise ArgumentError, ~r/needs a method or a notification/, fn ->
        Code.compile_string(
          "defmodule Sake.ExtensionTest.Empty do use Sake.Extension, id: \"com.example/e\" end"
        )
      end

      assert_raise ArgumentError, ~r/at least one \//, fn ->
        Code.compile_string(
          ~s(defmodule Sake.ExtensionTest.Flat do use Sake.Extension, id: "com.example/f"\n method "flat" end)
        )
      end
    end
  end

  describe "behind a proxy" do
    defmodule Router do
      use Plug.Router
      plug :match
      plug :dispatch

      forward "/mcp",
        to: Sake.Plug,
        init_opts: [server: Sake.ExtensionTest.Server, secret: String.duplicate("u", 64)]
    end

    defmodule Proxy do
      use Sake.Proxy, name: "ext-proxy", version: "1", upstream: "http://127.0.0.1:1/mcp"
    end

    defmodule OwnProxy do
      use Sake.Proxy, name: "own-proxy", version: "1", upstream: "http://127.0.0.1:1/mcp"
      extensions [Sake.ExtensionTest.ModernOnly]
    end

    test "the upstream's extensions are neither advertised nor forwarded; the proxy's own are served" do
      url = HTTP.start(Router) <> "/mcp"
      start_supervised!({Proxy, upstream: url})
      start_supervised!({OwnProxy, upstream: url})

      client = connect(Proxy)

      refute Map.has_key?(
               session(client).server_capabilities["extensions"] || %{},
               "com.example/widgets"
             )

      assert {:error, {:rpc, %{"code" => -32_601}}} = request(client, "widgets/list")

      own = connect(OwnProxy)
      assert Map.has_key?(session(own).server_capabilities["extensions"], "com.example/modern")
      assert {:ok, %{}} = request(own, "modern/ping")
      assert {:error, {:rpc, %{"code" => -32_601}}} = request(own, "widgets/list")
    end
  end
end
