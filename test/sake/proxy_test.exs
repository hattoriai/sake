defmodule Sake.ProxyTest do
  # Proxies are named processes (one per proxy module), started with each
  # test's own upstream URL.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Sake.Test

  alias Sake.Client.ToolResult
  alias SakeTest.{HTTP, Upstream}

  defmodule Proxy do
    use Sake.Proxy, name: "proxy", version: "1", upstream: "http://127.0.0.1:1/mcp"
  end

  defmodule Filtered do
    use Sake.Proxy,
      name: "filtered",
      version: "1",
      upstream: "http://127.0.0.1:1/mcp",
      tools: [except: ["whoami", "slow"]],
      prompts: false,
      resources: false,
      scope: "upstream",
      scopes: %{"add" => "upstream:add"}
  end

  defmodule Own do
    use Sake.Tool, name: "echo", description: "The proxy's own echo"

    @impl true
    def execute(_args, _ctx), do: {:ok, "own echo"}
  end

  defmodule Recorder do
    @moduledoc false
    def call(%{ctx: %{scope: %{test: pid}}} = payload, _opts) do
      send(
        pid,
        {:plug, payload.server, Map.get(payload, :tool, %{}) |> Map.get(:name),
         payload[:arguments]}
      )

      {:cont, payload}
    end

    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule HideWhoami do
    @moduledoc false
    def call(%{items: items} = payload, _opts),
      do: {:cont, %{payload | items: Enum.reject(items, &(&1.name == "whoami"))}}
  end

  defmodule WithOwn do
    use Sake.Proxy, name: "with-own", version: "1", upstream: "http://127.0.0.1:1/mcp"
    tools [Sake.ProxyTest.Own]
    middleware :before_call, [Recorder]
    middleware :after_list, [HideWhoami]
  end

  defmodule PerUser do
    use Sake.Proxy, name: "per-user", version: "1", upstream: "http://127.0.0.1:1/mcp"

    @impl Sake.Proxy
    def credentials(%Sake.Context{scope: %{token: token}}) when is_binary(token),
      do: {:bearer, token}

    def credentials(%Sake.Context{scope: %{tokens: agent}}),
      do: {:bearer, Agent.get_and_update(agent, fn [t | rest] -> {t, rest ++ [t]} end)}

    def credentials(%Sake.Context{scope: %{refuse: message}}), do: {:error, message}
    def credentials(_ctx), do: :none
  end

  defmodule Local do
    use Sake.Tool, name: "hello", description: "A local tool next to the proxied ones"

    @impl true
    def execute(_args, _ctx), do: {:ok, "local hello"}
  end

  defmodule LocalServer do
    use Sake.Server, name: "local", version: "1"
    tools [Local]
  end

  defmodule Gateway do
    use Sake.Server, name: "gateway", version: "1", instructions: "One endpoint."
    tools [SakeDev.Tools.Echo]
    mount LocalServer, prefix: "local"
    mount Sake.ProxyTest.Proxy, prefix: "up"
  end

  defmodule Outer do
    use Sake.Server, name: "outer", version: "1"
    mount Gateway, prefix: "gw"
  end

  defmodule OwnGateway do
    use Sake.Server, name: "own-gateway", version: "1"
    mount Sake.ProxyTest.WithOwn, prefix: "own"
    middleware :before_call, [Recorder]
  end

  @secret String.duplicate("g", 64)

  setup do
    %{url: HTTP.start(Upstream.Router) <> "/mcp"}
  end

  defp start_proxy(proxy, url, opts \\ []),
    do: start_supervised!({proxy, Keyword.put(opts, :upstream, url)})

  defp names(specs), do: Enum.map(specs, &(Map.get(&1, :name) || &1["name"]))

  describe "a proxy on its own" do
    for era <- [:modern, :legacy], upstream <- [:modern, :legacy] do
      test "lists and forwards (#{era} client, #{upstream} upstream)", %{url: url} do
        start_proxy(Proxy, url, connect: [era: unquote(upstream)])
        client = connect(Proxy, era: unquote(era))

        assert {:ok, tools} = list_tools(client)
        assert ["whoami", "link", "changes" | _] = names(tools)
        assert "echo" in names(tools) and "add" in names(tools)
        # Without MCP Apps, the app-only tool stays hidden, as upstream.
        refute "issue_details" in names(tools)
        assert Enum.find(tools, &(&1.name == "add")).input_schema["required"] == ["a", "b"]

        assert {:ok, %ToolResult{text: "hi"}} = call_tool(client, "echo", %{"text" => "hi"})

        assert {:ok, %ToolResult{structured: %{"sum" => 3}}} =
                 call_tool(client, "add", %{"a" => 1, "b" => 2})

        # The upstream validates the arguments, and its tool error comes back.
        assert {:ok, %ToolResult{is_error: true, text: "Invalid arguments" <> _}} =
                 call_tool(client, "add", %{"a" => "one"})

        assert {:error, {:rpc, %{"code" => -32_602, "message" => "Unknown tool: nope"}}} =
                 call_tool(client, "nope", %{})

        assert {:ok, resources} = list_resources(client)
        assert "dev://readme" in Enum.map(resources, & &1["uri"])
        assert {:ok, [%{"uriTemplate" => "issue://{id}"}]} = list_resource_templates(client)

        assert {:ok, [%Sake.Content{uri: "issue://2", text: text}]} =
                 read_resource(client, "issue://2")

        assert text =~ "Export is slow"

        assert {:error, {:rpc, %{"data" => %{"uri" => "issue://9"}}}} =
                 read_resource(client, "issue://9")

        assert {:ok, [%{"name" => "triage"}]} = list_prompts(client)

        assert {:ok,
                %{"messages" => [%{"content" => %{"text" => "Triage issue 7 in a direct tone."}}]}} =
                 get_prompt(client, "triage", %{"id" => "7", "tone" => "direct"})

        assert {:ok, %{"values" => ["direct"]}} =
                 complete(client, {:prompt, "triage"}, "tone", "d")

        assert {:ok, %{"values" => ["1"]}} =
                 complete(client, {:resource, "issue://{id}"}, "id", "1")
      end
    end

    test "describes itself as the server it is", %{url: url} do
      start_proxy(Proxy, url)
      session = session(connect(Proxy))
      assert session.server_info["name"] == "proxy"
      caps = session.server_capabilities
      assert caps["tools"] && caps["resources"] && caps["prompts"] && caps["completions"]
      assert Map.has_key?(caps["extensions"], "io.modelcontextprotocol/tasks")
    end

    test "lists are private and kept for the upstream's ttl", %{url: url} do
      start_proxy(Proxy, url)
      client = connect(Proxy)
      session = session(client)

      assert {:ok, %{"cacheScope" => "private", "ttlMs" => ttl}, _} =
               Sake.Client.request(session, "tools/list", %{})

      assert ttl <= 300_000
    end

    @tag :capture_log
    test "an upstream that cannot be reached lists nothing", %{url: _url} do
      start_proxy(Proxy, "http://127.0.0.1:1/mcp")
      client = connect(Proxy)

      log = capture_log(fn -> assert {:ok, []} = list_tools(client) end)
      assert log =~ "could not list the upstream's tools"
      assert {:error, {:rpc, %{"code" => -32_602}}} = call_tool(client, "echo", %{"text" => "x"})
    end

    test "the proxy's own components come first, and an upstream one never shadows them",
         %{url: url} do
      start_proxy(WithOwn, url)
      client = connect(WithOwn, scope: %{test: self()})

      assert {:ok, tools} = list_tools(client)
      assert ["echo", "link" | _] = names(tools)
      assert Enum.count(tools, &(&1.name == "echo")) == 1
      # The proxy's own middleware hides an upstream tool, in the list and
      # for calls.
      refute "whoami" in names(tools)

      assert {:ok, %ToolResult{text: "own echo"}} = call_tool(client, "echo", %{})

      assert {:error, {:rpc, %{"message" => "Unknown tool: whoami"}}} =
               call_tool(client, "whoami", %{})

      # The proxy's middleware sees a proxied call's arguments as the
      # client sent them.
      assert {:ok, _} = call_tool(client, "add", %{"a" => 1, "b" => 2})
      assert_received {:plug, WithOwn, "add", %{"a" => 1, "b" => 2}}
    end
  end

  describe "what a proxy exposes" do
    test "only, except, and the scopes it requires", %{url: url} do
      start_proxy(Filtered, url)

      client = connect(Filtered, scopes: ["upstream"])
      assert {:ok, tools} = list_tools(client)
      refute "whoami" in names(tools)
      refute "slow" in names(tools)
      refute "add" in names(tools)
      assert "echo" in names(tools)
      assert {:ok, []} = list_prompts(client)
      assert {:ok, []} = list_resources(client)

      assert {:error, {:insufficient_scope, %{scope: ["upstream", "upstream:add"]}}} =
               call_tool(client, "add", %{"a" => 1, "b" => 2})

      assert {:error, {:rpc, %{"message" => "Unknown tool: whoami"}}} =
               call_tool(client, "whoami", %{})

      client = connect(Filtered, scopes: ["upstream", "upstream:add"])

      assert {:ok, %ToolResult{structured: %{"sum" => 3}}} =
               call_tool(client, "add", %{"a" => 1, "b" => 2})

      session = session(client)
      refute session.server_capabilities["prompts"]
      refute session.server_capabilities["resources"]
    end
  end

  describe "mounted" do
    test "a proxy mounted under a prefix, next to local tools and servers", %{url: url} do
      start_proxy(Proxy, url)
      client = connect(Gateway, ui: true)

      assert {:ok, tools} = list_tools(client)
      assert ["echo", "local_hello", "up_whoami", "up_link" | _] = names(tools)
      assert "up_echo" in names(tools)

      # An MCP App of the upstream: the tool's link takes the prefix, and
      # the app is one of the gateway's resources.
      board = Enum.find(tools, &(&1.name == "up_issue_board"))
      assert board.ui == "ui://up/sake-dev/issue-board"
      assert board.meta["ui"]["resourceUri"] == "ui://up/sake-dev/issue-board"
      assert "up_issue_details" in names(tools)

      assert {:ok, %ToolResult{text: "local hello"}} = call_tool(client, "local_hello", %{})
      assert {:ok, %ToolResult{text: "hi"}} = call_tool(client, "up_echo", %{"text" => "hi"})

      assert {:ok, resources} = list_resources(client)
      uris = Enum.map(resources, & &1["uri"])
      assert "dev://up/readme" in uris
      assert "ui://up/sake-dev/issue-board" in uris
      assert {:ok, [%{"uriTemplate" => "issue://up/{id}"}]} = list_resource_templates(client)

      assert {:ok, [%Sake.Content{uri: "issue://up/1"}]} = read_resource(client, "issue://up/1")

      assert {:ok, [%Sake.Content{uri: "ui://up/sake-dev/issue-board"}]} =
               read_resource(client, "ui://up/sake-dev/issue-board")

      # Links to the upstream's resources take the prefix; others do not.
      assert {:ok, %ToolResult{content: [_, issue, page, embedded]}} =
               call_tool(client, "up_link", %{})

      assert issue.uri == "issue://up/1"
      assert page.uri == "https://example.com/1"
      assert embedded.uri == "dev://up/readme"

      # Any URI under the prefix goes upstream, which answers for it.
      assert {:error, {:rpc, %{"data" => %{"uri" => "nope://up/x"}}}} =
               read_resource(client, "nope://up/x")

      assert {:error, {:rpc, _}} = read_resource(client, "issue://1")

      assert {:ok, %{"messages" => [_]}} = get_prompt(client, "up_triage", %{"id" => "1"})

      assert {:ok, %{"values" => ["kind"]}} =
               complete(client, {:prompt, "up_triage"}, "tone", "k")

      assert {:ok, %{"values" => ["2"]}} =
               complete(client, {:resource, "issue://up/{id}"}, "id", "2")
    end

    test "the proxy's own middleware runs inside the parent's, with the upstream's names",
         %{url: url} do
      start_proxy(WithOwn, url)
      client = connect(OwnGateway, scope: %{test: self()})

      assert {:ok, tools} = list_tools(client)
      assert ["own_echo", "own_link" | _] = names(tools)
      refute "own_whoami" in names(tools)

      assert {:ok, %ToolResult{structured: %{"sum" => 3}}} =
               call_tool(client, "own_add", %{"a" => 1, "b" => 2})

      assert_received {:plug, OwnGateway, "own_add", %{"a" => 1, "b" => 2}}
      assert_received {:plug, WithOwn, "add", %{"a" => 1, "b" => 2}}

      assert {:error, {:rpc, %{"message" => "Unknown tool: own_whoami"}}} =
               call_tool(client, "own_whoami", %{})
    end

    test "through the endpoint, over HTTP", %{url: url} do
      start_proxy(Proxy, url)
      client = connect(Gateway, plug: {Sake.Plug, server: Gateway, secret: @secret})

      # The client mirrors `add`'s `precision` into its header, as the
      # tool it listed asks, and the gateway checks it against the proxied
      # tool's schema.
      assert {:ok, _tools} = list_tools(client)

      assert {:ok, %ToolResult{structured: %{"sum" => 3.0}}} =
               call_tool(client, "up_add", %{"a" => 1, "b" => 2, "precision" => 1})

      assert {:ok, [%Sake.Content{uri: "issue://up/1"}]} = read_resource(client, "issue://up/1")

      client = connect(Gateway, plug: {Sake.Plug, server: Gateway, secret: @secret}, era: :legacy)
      assert {:ok, %ToolResult{text: "hi"}} = call_tool(client, "up_echo", %{"text" => "hi"})
    end

    test "under two prefixes", %{url: url} do
      start_proxy(Proxy, url)
      client = connect(Outer)

      assert {:ok, %ToolResult{content: [_, issue | _]}} = call_tool(client, "gw_up_link", %{})
      assert issue.uri == "issue://gw/up/1"

      assert {:ok, [%Sake.Content{uri: "issue://gw/up/1"}]} =
               read_resource(client, "issue://gw/up/1")
    end
  end

  describe "credentials" do
    test "each principal acts as itself upstream", %{url: url} do
      start_proxy(PerUser, url)

      ana = connect(PerUser, scope: %{token: "ana-token"})
      bo = connect(PerUser, scope: %{token: "bo-token"})
      nobody = connect(PerUser)

      assert {:ok, %ToolResult{text: ~s(upstream sees "ana-token")}} =
               call_tool(ana, "whoami", %{})

      assert {:ok, %ToolResult{text: ~s(upstream sees "bo-token")}} = call_tool(bo, "whoami", %{})
      assert {:ok, %ToolResult{text: "upstream sees nil"}} = call_tool(nobody, "whoami", %{})

      # One session per principal and credential, never shared.
      sessions = for {{:session, key}, _session, _used} <- :ets.tab2list(PerUser), do: key
      assert length(Enum.uniq_by(sessions, &elem(&1, 0))) == 3
    end

    test "a principal without credentials sees no proxied components, and a call is refused",
         %{url: url} do
      start_proxy(PerUser, url)
      client = connect(PerUser, scope: %{refuse: "Connect your account first."})

      assert {:ok, []} = list_tools(client)

      assert {:error, {:rpc, %{"code" => -32_602}}} = call_tool(client, "whoami", %{})
    end

    test "a refused session is opened again once, with the credentials asked for again",
         %{url: url} do
      start_proxy(PerUser, String.replace(url, "/mcp", "/strict/mcp"))
      Upstream.allow(["fresh"])
      on_exit(fn -> Upstream.allow([]) end)

      # The first token is refused; the second, asked for after the 401,
      # is taken.
      {:ok, tokens} = Agent.start_link(fn -> ["stale", "fresh"] end)
      client = connect(PerUser, scope: %{tokens: tokens})

      assert {:ok, %ToolResult{text: ~s(upstream sees "fresh")}} =
               call_tool(client, "whoami", %{})

      # A token still refused after the second try: nothing to list.
      {:ok, tokens} = Agent.start_link(fn -> ["stale"] end)
      client = connect(PerUser, scope: %{tokens: tokens})
      log = capture_log(fn -> assert {:ok, []} = list_tools(client) end)
      assert log =~ "could not list the upstream's tools"
    end
  end

  describe "questions" do
    for era <- [:modern, :legacy], upstream <- [:modern, :legacy] do
      test "elicitation, sampling and roots go to the client (#{era} client, #{upstream} upstream)",
           %{url: url} do
        start_proxy(Proxy, url, connect: [era: unquote(upstream)])

        client =
          connect(Proxy,
            era: unquote(era),
            on_input: fn _params -> {:accept, %{"name" => "Rui"}} end,
            sampling: fn _params -> "Short." end,
            roots: [%{"uri" => "file:///w", "name" => "W"}]
          )

        assert {:ok, %ToolResult{text: "Hello, Rui!"}} = call_tool(client, "confirm", %{})
        assert_asked "elicitation/create", %{"message" => "Who should be greeted?"}

        assert {:ok, %ToolResult{text: "Short."}} =
                 call_tool(client, "summarize", %{"text" => "Long."})

        assert_asked "sampling/createMessage", %{"maxTokens" => 100}

        assert {:ok, %ToolResult{text: "file:///w (W)"}} = call_tool(client, "roots", %{})
        assert_asked "roots/list"
      end
    end

    for era <- [:modern, :legacy], upstream <- [:modern, :legacy] do
      test "several rounds, and several questions at once (#{era} client, #{upstream} upstream)",
           %{url: url} do
        start_proxy(Proxy, url, connect: [era: unquote(upstream)])

        answer = fn
          %{"message" => "Step 1" <> _} -> {:accept, %{"name" => "Rui"}}
          %{"message" => "Step 2" <> _} -> {:accept, %{"color" => "teal"}}
          %{"message" => "First" <> _} -> {:accept, %{"name" => "Ana"}}
          %{"message" => "Second" <> _} -> {:accept, %{"name" => "Bo"}}
        end

        client = connect(Proxy, era: unquote(era), tasks: false, on_input: answer)

        assert {:ok, %ToolResult{text: "Rui likes teal."}} =
                 call_tool(client, "test_input_required_result_multi_round", %{})

        assert {:ok, %ToolResult{text: "Answered: Ana, Bo"}} =
                 call_tool(client, "multi_input", %{})
      end
    end

    test "a client that cannot answer gets the upstream's answer to that", %{url: url} do
      start_proxy(Proxy, url)
      client = connect(Proxy)

      assert {:ok,
              %ToolResult{
                is_error: true,
                text: "This tool needs a client that supports elicitation."
              }} =
               call_tool(client, "confirm", %{})
    end

    test "the request state carries the upstream's, bound to the principal", %{url: url} do
      start_proxy(Proxy, url)

      caps = %{"elicitation" => %{}}
      ana = connect(Proxy, scope: :ana, capabilities: caps)
      bo = connect(Proxy, scope: :bo, capabilities: caps)

      assert {:ok, %{"resultType" => "input_required", "requestState" => state} = asked, _} =
               Sake.Client.request(session(ana), "tools/call", %{
                 "name" => "confirm",
                 "arguments" => %{}
               })

      assert %{"who" => %{"method" => "elicitation/create"}} = asked["inputRequests"]

      retry = %{
        "name" => "confirm",
        "arguments" => %{},
        "requestState" => state,
        "inputResponses" => %{"who" => %{"action" => "accept", "content" => %{"name" => "Ana"}}}
      }

      # Another principal cannot use it.
      assert {:error, {:rpc, %{"message" => "Invalid request state"}}, _} =
               Sake.Client.request(session(bo), "tools/call", retry)

      # A client cannot slip its own upstream state in with its answers.
      forged =
        put_in(retry, ["inputResponses", "ai.hattori.sake/upstream"], %{
          "state" => "x",
          "keys" => []
        })

      assert {:ok, %{"content" => [%{"text" => "Hello, Ana!"}]}, _} =
               Sake.Client.request(session(ana), "tools/call", forged)
    end
  end

  describe "notifications of a call" do
    test "progress and log messages reach the client", %{url: url} do
      start_proxy(Proxy, url)
      client = connect(Proxy, log_level: "info")

      assert {:ok, %ToolResult{text: "counted to 2"}} =
               call_tool(client, "slow", %{"n" => 2, "delay_ms" => 0})

      assert_notification "notifications/progress", %{"progress" => 1, "total" => 2}
      assert_notification "notifications/progress", %{"progress" => 2, "total" => 2}

      assert {:ok, %ToolResult{text: "Done."}} = call_tool(client, "test_tool_with_logging", %{})

      assert_notification "notifications/message", %{
        "level" => "info",
        "data" => "Tool execution started"
      }

      assert_notification "notifications/message", %{"data" => "Tool execution completed"}
    end

    test "a legacy client hears them too, from a legacy upstream", %{url: url} do
      start_proxy(Proxy, url, connect: [era: :legacy])
      client = connect(Proxy, era: :legacy)

      assert {:ok, _} = call_tool(client, "slow", %{"n" => 2, "delay_ms" => 0})
      assert_notification "notifications/progress", %{"progress" => 2, "total" => 2}
    end
  end

  describe "a stdio upstream" do
    defp stdio, do: SakeTest.StdioScript.server()

    for upstream <- [:modern, :legacy] do
      test "is one process for every principal, asked one request at a time (#{upstream})" do
        start_supervised!(
          {Proxy, upstream: stdio(), connect: [era: unquote(upstream), stderr: :ignore]}
        )

        ana = connect(Proxy, scope: :ana)
        bo = connect(Proxy, scope: :bo, on_input: fn _ -> {:accept, %{"name" => "Bo"}} end)

        assert {:ok, tools} = list_tools(ana)
        assert "echo" in names(tools)

        calls =
          for i <- 1..6 do
            client = if rem(i, 2) == 0, do: ana, else: bo
            Task.async(fn -> call_tool(client, "echo", %{"text" => "#{i}"}) end)
          end

        texts = for {:ok, %ToolResult{text: text}} <- Task.await_many(calls, 30_000), do: text
        assert Enum.sort(texts) == ~w(1 2 3 4 5 6)

        # A question goes to the client of the call that asked it.
        assert {:ok, %ToolResult{text: "Hello, Bo!"}} = call_tool(bo, "confirm", %{})

        assert {:ok, %ToolResult{is_error: true}} = call_tool(ana, "confirm", %{})
        assert {:ok, %ToolResult{text: "hi"}} = call_tool(ana, "echo", %{"text" => "hi"})
      end
    end
  end

  describe "upstream notifications" do
    for transport <- [:http, :stdio], upstream <- [:modern, :legacy] do
      test "list changes and followed resources reach the clients, renamed (#{transport}, #{upstream})",
           %{url: url} do
        target =
          case unquote(transport) do
            :http -> url
            :stdio -> SakeTest.StdioScript.script("upstream")
          end

        start_proxy(Proxy, target, connect: [era: unquote(upstream), stderr: :ignore])
        listen(Gateway, shared: true)
        client = connect(Gateway)

        # The upstream's announcement reaches the gateway's clients once the
        # proxy follows the upstream.
        until_heard(client, "up_changes", {:list_changed, :tools})

        # Nobody follows issue://1 yet: its update is not asked for.
        refute_received {:sake_test_broadcast, _, {:resource_updated, _}}

        # A legacy client subscribes to it through the gateway; the proxy
        # follows it upstream, and its updates reach the client renamed.
        legacy = connect(Gateway, era: :legacy)

        assert {:ok, %{}, _} =
                 Sake.Client.request(session(legacy), "resources/subscribe", %{
                   "uri" => "issue://up/1"
                 })

        until_heard(client, "up_changes", {:resource_updated, "issue://up/1"})
      end
    end

    test "the cached lists are forgotten on a list change", %{url: url} do
      start_proxy(Proxy, url)
      listen(Proxy, shared: true)
      client = connect(Proxy)
      until_heard(client, "changes", {:list_changed, :tools})

      assert {:ok, _} = list_tools(client)
      assert [_] = for({{:list, _, :tools}, _, _} <- :ets.tab2list(Proxy), do: :list)

      until_heard(client, "changes", {:list_changed, :tools})
      assert [] = for({{:list, _, :tools}, _, _} <- :ets.tab2list(Proxy), do: :list)
    end

    test "a proxy with credentials per principal does not follow its upstream", %{url: url} do
      start_proxy(PerUser, url)
      refute Sake.Proxy.Watcher.subscribe?(PerUser)
      refute session(connect(PerUser)).server_capabilities["resources"]["subscribe"]
    end

    # The proxy follows its upstream a moment after it starts (and again
    # after each new subscription): the tool announces until the broadcast
    # is heard.
    defp until_heard(client, tool, event, tries \\ 40) do
      assert {:ok, _} = call_tool(client, tool, %{})

      receive do
        {:sake_test_broadcast, _server, ^event} -> :ok
      after
        250 ->
          if tries == 0, do: flunk("never heard #{inspect(event)}")
          until_heard(client, tool, event, tries - 1)
      end
    end
  end

  describe "the development server's gateway" do
    defmodule Open do
      @moduledoc false
      use Plug.Router
      plug :match
      plug :dispatch

      forward "/open/mcp",
        to: Sake.Plug,
        init_opts: [server: SakeDev.ConformanceServer, secret: String.duplicate("o", 64)]
    end

    test "mounts the example server and proxies the open one" do
      url = HTTP.start(Open) <> "/open/mcp"
      start_supervised!({SakeDev.Gateway.Open, upstream: url})
      client = connect(SakeDev.Gateway, scopes: ["issues:read", "issues:write"])

      assert {:ok, tools} = list_tools(client)
      assert "dev_echo" in names(tools)
      assert "open_test_simple_text" in names(tools)
      refute "open_test_image_content" in names(tools)

      assert {:ok, [%{"name" => "dev_triage"}, %{"name" => "open_test_simple_prompt"}]} =
               list_prompts(client)

      assert {:ok, %ToolResult{text: "hi"}} = call_tool(client, "dev_echo", %{"text" => "hi"})

      assert {:ok, %ToolResult{text: "This is a simple text response for testing."}} =
               call_tool(client, "open_test_simple_text", %{})

      # The proxy requires the gateway's scope, which the open endpoint
      # does not.
      client = connect(SakeDev.Gateway, scopes: [])

      assert {:error, {:insufficient_scope, %{scope: ["issues:read"]}}} =
               call_tool(client, "open_test_simple_text", %{})
    end
  end

  describe "sessions" do
    test "a legacy session the upstream no longer knows is opened again", %{url: url} do
      start_proxy(Proxy, url, connect: [era: :legacy])
      client = connect(Proxy, scope: :ana)
      assert {:ok, _} = call_tool(client, "echo", %{"text" => "x"})

      [{key, session, used}] = for {{:session, _}, _, _} = row <- :ets.tab2list(Proxy), do: row
      :ets.insert(Proxy, {key, %{session | session_id: "forgotten"}, used})

      assert {:ok, %ToolResult{text: "y"}} = call_tool(client, "echo", %{"text" => "y"})
      assert [{_, %{session_id: id}, _}] = :ets.lookup(Proxy, key)
      assert id != "forgotten"
    end

    test "an unused session is closed after the idle timeout", %{url: url} do
      pid = start_proxy(Proxy, url, idle_timeout: 0)
      client = connect(Proxy, scope: :ana)
      assert {:ok, _} = call_tool(client, "echo", %{"text" => "x"})
      assert [_] = for({{:session, _}, _, _} <- :ets.tab2list(Proxy), do: :session)

      send(pid, :sweep)
      _ = :sys.get_state(pid)
      assert [] = for({{:session, _}, _, _} <- :ets.tab2list(Proxy), do: :session)

      # The next call opens a new one.
      assert {:ok, %ToolResult{text: "y"}} = call_tool(client, "echo", %{"text" => "y"})
    end
  end

  describe "tasks" do
    test "an upstream's task becomes the proxy's own", %{url: url} do
      start_proxy(Proxy, url)
      client = connect(Proxy, scope: :ana, on_input: fn _ -> {:accept, %{"format" => "csv"}} end)

      assert {:ok, {:task, task}} =
               call_tool_async(client, "export", %{"n" => 2, "delay_ms" => 0})

      assert {:ok, %Sake.Tasks.Record{tool: "export"}} = Sake.Tasks.fetch(task["taskId"])

      # The upstream's question, asked through the proxy's task.
      assert {:ok, %{"status" => "input_required", "inputRequests" => %{"format" => _}}} =
               await_task(client, task)

      # Another principal does not see it.
      other = connect(Proxy, scope: :bo)

      assert {:error, {:rpc, %{"message" => "Failed to retrieve task: Task not found"}}} =
               get_task(other, task["taskId"])

      assert :ok =
               update_task(client, task["taskId"], %{
                 "format" => %{"action" => "accept", "content" => %{"format" => "json"}}
               })

      assert {:ok, %{"status" => "completed", "result" => result}} = await_task(client, task)
      assert %{"content" => [%{"text" => "Exported 2 issues as json."}]} = result

      # call_tool follows it to the end, answering as it goes.
      assert {:ok, %ToolResult{text: "Exported 1 issues as csv."}} =
               call_tool(client, "export", %{"n" => 1, "delay_ms" => 0})
    end

    test "cancelling the proxy's task cancels the upstream's", %{url: url} do
      start_proxy(Proxy, url)
      client = connect(Proxy, scope: :ana, capabilities: %{"elicitation" => %{}})

      Sake.Test.listen(SakeTest.Upstream, shared: true)

      assert {:ok, {:task, task}} =
               call_tool_async(client, "export", %{"n" => 50, "delay_ms" => 100})

      assert {:ok, %{"status" => "input_required"}} = await_task(client, task)
      assert :ok = cancel_task(client, task["taskId"])
      assert {:ok, %{"status" => "cancelled"}} = get_task(client, task["taskId"])

      assert_receive {:sake_test_broadcast, SakeTest.Upstream,
                      {:task, %{"status" => "cancelled"}}},
                     2_000
    end

    test "an upstream's task is cancelled there when the caller has no room for another",
         %{url: url} do
      config = Sake.Tasks.config()
      :persistent_term.put({Sake.Tasks, :config}, %{config | max_per_principal: 2})
      on_exit(fn -> :persistent_term.put({Sake.Tasks, :config}, config) end)

      start_proxy(Proxy, url)
      client = connect(Proxy, scope: :ana, capabilities: %{"elicitation" => %{}})
      Sake.Test.listen(SakeTest.Upstream, shared: true)

      assert {:ok, {:task, task}} =
               call_tool_async(client, "export", %{"n" => 50, "delay_ms" => 100})

      # The proxy's caller fills its second slot; the upstream, in this
      # same node, still has room for the proxy's next task.
      {:ok, record} = Sake.Tasks.fetch(task["taskId"])
      %{store: {module, state}} = config
      :ok = module.insert(state, %{record | id: "filler"}, :infinity)

      assert {:error, {:rpc, %{"code" => -32_600}}} =
               call_tool_async(client, "export", %{"n" => 50, "delay_ms" => 100})

      assert_receive {:sake_test_broadcast, SakeTest.Upstream,
                      {:task, %{"status" => "cancelled"}}},
                     2_000

      assert :ok = cancel_task(client, task["taskId"])

      assert_receive {:sake_test_broadcast, SakeTest.Upstream,
                      {:task, %{"status" => "cancelled"}}},
                     2_000
    end

    test "a client without tasks gets the result in the call", %{url: url} do
      start_proxy(Proxy, url)
      client = connect(Proxy, tasks: false, on_input: fn _ -> {:accept, %{"format" => "csv"}} end)

      assert {:ok, %ToolResult{text: "Exported 1 issues as csv."}} =
               call_tool(client, "export", %{"n" => 1, "delay_ms" => 0})
    end
  end
end
