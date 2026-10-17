defmodule Sake.MiddlewareTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Sake.Test

  alias Sake.Auth.Challenge
  alias Sake.Client.ToolResult
  alias SakeTest.{LegacyClient, ModernClient}

  # The principal (`ctx.scope`) drives the plugs: `plan:` for the plan
  # filter, `tenant:` for the tenant injection, `test:` for the audit, and
  # `halt:`, `raise:` and `bad:` (an event) for the switch.

  defmodule Switch do
    @moduledoc false
    @behaviour Sake.Middleware

    @impl true
    def init(opts), do: Keyword.fetch!(opts, :event)

    @impl true
    def call(%{ctx: %{scope: %{} = scope}} = payload, event) do
      cond do
        halt = halt(scope[:halt], event, payload.method) -> {:halt, halt}
        scope[:raise] == event -> raise "plug failed on #{event}"
        scope[:bad] == event -> {:cont, Map.put(payload, bad_key(event), "not a map")}
        true -> {:cont, payload}
      end
    end

    def call(payload, _event), do: {:cont, payload}

    # `{event, reason}`, or `{event, reason, method}` for one method only.
    defp halt({event, reason}, event, _method), do: reason
    defp halt({event, reason, method}, event, method), do: reason
    defp halt(_halt, _event, _method), do: nil

    defp bad_key(:before_call), do: :arguments
    defp bad_key(:after_list), do: :items
    defp bad_key(_event), do: :result
  end

  defmodule Plans do
    @moduledoc false
    @behaviour Sake.Middleware

    @impl true
    def init(opts), do: MapSet.new(Keyword.fetch!(opts, :pro))

    @impl true
    def call(%{items: items, ctx: %{scope: %{plan: :free}}} = payload, pro),
      do: {:cont, %{payload | items: Enum.reject(items, &MapSet.member?(pro, key(&1)))}}

    def call(payload, _pro), do: {:cont, payload}

    defp key(%Sake.Resource.Spec{uri: uri}), do: uri
    defp key(%{name: name}), do: name
  end

  defmodule Tenant do
    @moduledoc false
    def call(%{ctx: %{scope: %{tenant: tenant}}, assigns: assigns} = payload, _opts) do
      payload = %{payload | assigns: Map.put(assigns, :tenant, tenant)}

      case payload do
        %{arguments: args} -> {:cont, %{payload | arguments: Map.put(args, :tenant, tenant)}}
        %{params: params} -> {:cont, %{payload | params: Map.put(params, :tenant, tenant)}}
        _ -> {:cont, payload}
      end
    end

    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule Audit do
    @moduledoc false
    def call(%{ctx: %{scope: %{test: pid}}} = payload, _opts) do
      send(pid, {:audit, payload.method, Map.drop(payload, [:ctx, :server])})
      {:cont, payload}
    end

    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule Redact do
    @moduledoc false
    def call(%{result: result} = payload, _opts),
      do: {:cont, %{payload | result: redact(result)}}

    defp redact(%{} = map), do: Map.new(map, fn {k, v} -> {k, redact(v)} end)
    defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
    defp redact(text) when is_binary(text), do: String.replace(text, "s3cr3t", "[redacted]")
    defp redact(other), do: other
  end

  defmodule Confirm do
    @moduledoc false
    # Asks the person before a call, as a tool's `prepare/2` can.
    def call(%{ctx: %{scope: %{confirm: true}} = ctx} = payload, _opts) do
      schema = %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}

      case Sake.Elicit.form(ctx, :proceed, "Proceed?", schema) do
        {:ok, %{"ok" => true}} -> {:cont, payload}
        _ -> {:halt, {:tool_error, "Not confirmed."}}
      end
    end

    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule Whoami do
    use Sake.Tool, name: "whoami", description: "Says what it was given"
    arg :text, :string

    @impl true
    def execute(args, ctx),
      do: {:ok, "#{args[:text]} for #{args[:tenant]} (#{inspect(ctx.assigns[:tenant])}): s3cr3t"}
  end

  defmodule Export do
    use Sake.Tool, name: "export", description: "A pro tool"

    @impl true
    def execute(_args, _ctx), do: {:ok, "exported"}
  end

  defmodule Report do
    use Sake.Tool, name: "report", description: "A task", task: :optional

    @impl true
    def execute(args, _ctx), do: {:ok, "report for #{args[:tenant]}: s3cr3t"}
  end

  defmodule Note do
    use Sake.Resource, uri: "note://{id}", name: "note", subscribe: true

    @impl true
    def read(params, _ctx), do: {:ok, "note #{params.id} of #{params[:tenant]}: s3cr3t"}

    @impl true
    def complete("id", _partial, _ctx), do: {:ok, ["1", "2"]}
  end

  defmodule Vault do
    use Sake.Resource, uri: "vault://keys", name: "vault", subscribe: true

    @impl true
    def read(_params, _ctx), do: {:ok, "keys"}
  end

  defmodule Greet do
    use Sake.Prompt, name: "greet", description: "Greets"
    arg :name, :string, required: true

    @impl true
    def get(args, _ctx), do: {:ok, [user: "Hello, #{args.name} of #{args[:tenant]}: s3cr3t"]}
  end

  defmodule Pitch do
    use Sake.Prompt, name: "pitch", description: "A pro prompt"
    arg :product, :string

    @impl true
    def get(_args, _ctx), do: {:ok, [user: "Buy it."]}

    @impl true
    def complete("product", _partial, _ctx), do: {:ok, ["sake"]}
  end

  defmodule Server do
    use Sake.Server, name: "middleware-test", version: "1"

    tools [Whoami, Export, Report, SakeDev.Tools.Confirm]
    resources [Note, Vault]
    prompts [Greet, Pitch]

    for event <- Sake.Middleware.events() do
      middleware event, [{Switch, event: event}]
    end

    middleware :before_request, [Audit]
    middleware :after_list, [{Plans, pro: ["export", "vault://keys", "pitch"]}]
    middleware :before_call, [Tenant, Audit, Confirm]
    middleware :after_call, [Audit, Redact]
    middleware :before_read, [Tenant, Audit]
    middleware :after_read, [Redact]
    middleware :before_get, [Tenant]
    middleware :after_get, [Redact]
  end

  defmodule Plain do
    use Sake.Server, name: "plain", version: "1"
    tools [Whoami]
    resources [Note]
  end

  defp scope(extra \\ []), do: Map.new([plan: :pro, tenant: "acme", test: self()] ++ extra)

  defp text(%ToolResult{text: text}), do: text

  # The audits of `method`'s requests (`:params`: the assigns each one
  # started with) or of its `:before_call`s (`:arguments`), in order.
  defp audits(method, key) do
    receive do
      {:audit, ^method, %{^key => _} = audit} when not is_map_key(audit, :result) ->
        [if(key == :params, do: audit.assigns, else: audit) | audits(method, key)]
    after
      0 -> []
    end
  end

  for era <- [:modern, :legacy] do
    describe "#{era}" do
      @era era

      test "before_call rewrites the arguments, the assigns reach the tool, after_call redacts" do
        client = connect(Server, era: @era, scope: scope())

        assert {:ok, %ToolResult{is_error: false} = result} =
                 call_tool(client, "whoami", %{"text" => "hi"})

        assert text(result) == ~s|hi for acme ("acme"): [redacted]|

        assert_received {:audit, "tools/call", %{assigns: %{}, params: %{"name" => "whoami"}}}

        assert_received {:audit, "tools/call",
                         %{tool: %{name: "whoami"}, arguments: %{tenant: "acme", text: "hi"}}}

        # The after plugs see what the before plugs decided.
        assert_received {:audit, "tools/call", %{assigns: %{tenant: "acme"}, result: result}}

        assert result["content"] == [
                 %{"type" => "text", "text" => ~s|hi for acme ("acme"): s3cr3t|}
               ]
      end

      test "before_read and before_get rewrite, after_read and after_get redact" do
        client = connect(Server, era: @era, scope: scope())

        assert {:ok, [%{text: "note 7 of acme: [redacted]"}]} = read_resource(client, "note://7")
        assert_received {:audit, "resources/read", %{uri: "note://7", params: %{id: "7"}}}

        assert {:ok, %{"messages" => [%{"content" => %{"text" => text}}]}} =
                 get_prompt(client, "greet", %{"name" => "Rui"})

        assert text == "Hello, Rui of acme: [redacted]"
      end

      test "after_list hides a component from the list and from every call" do
        free = connect(Server, era: @era, scope: scope(plan: :free))
        pro = connect(Server, era: @era, scope: scope())

        assert {:ok, tools} = list_tools(free)
        assert Enum.map(tools, & &1.name) == ["whoami", "report", "confirm"]
        assert {:ok, tools} = list_tools(pro)
        assert Enum.map(tools, & &1.name) == ["whoami", "export", "report", "confirm"]

        assert {:error, {:rpc, %{"code" => -32_602, "message" => "Unknown tool: export"}}} =
                 call_tool(free, "export")

        assert {:ok, %ToolResult{text: "exported"}} = call_tool(pro, "export")

        assert {:ok, []} = list_resources(free)
        assert {:ok, templates} = list_resource_templates(free)
        assert Enum.map(templates, & &1["uriTemplate"]) == ["note://{id}"]

        code = if @era == :legacy, do: -32_002, else: -32_602

        assert {:error, {:rpc, %{"code" => ^code, "data" => %{"uri" => "vault://keys"}}}} =
                 read_resource(free, "vault://keys")

        assert {:ok, [%{text: "keys"}]} = read_resource(pro, "vault://keys")

        assert {:ok, prompts} = list_prompts(free)
        assert Enum.map(prompts, & &1["name"]) == ["greet"]

        assert {:error, {:rpc, %{"code" => -32_602, "message" => "Unknown prompt: pitch"}}} =
                 get_prompt(free, "pitch")

        ref = {:prompt, "pitch"}

        assert {:error, {:rpc, %{"message" => "Unknown completion reference"}}} =
                 complete(free, ref, "product", "s")

        assert {:ok, %{"values" => ["sake"]}} = complete(pro, ref, "product", "s")
      end

      test "the halt's reason decides what the client gets" do
        call = fn reason ->
          client = connect(Server, era: @era, scope: scope(halt: {:before_call, reason}))
          call_tool(client, "whoami", %{"text" => "hi"})
        end

        assert {:error, {:rpc, %{"code" => -32_602, "message" => "Unknown tool: whoami"}}} =
                 call.(:not_found)

        assert {:error, {:rpc, %{"code" => -32_600, "message" => "Slow down"}}} =
                 call.({:error, "Slow down"})

        assert {:ok, %ToolResult{is_error: true, text: "Upgrade to Pro"}} =
                 call.({:tool_error, "Upgrade to Pro"})

        assert {:error, {:http, 403, %{"error" => %{"message" => "Forbidden"}}}} =
                 call.(:forbidden)

        assert {:error, {:insufficient_scope, %Challenge{scope: ["admin"]}}} =
                 call.({:forbidden, ["admin"]})

        # A reason the vocabulary does not know is never shown.
        assert {:error, {:rpc, %{"code" => -32_600, "message" => "Request refused"}}} =
                 call.({:db, "password=hunter2"})

        refute_received {:audit, "tools/call", %{arguments: _}}
      end

      test "a halt stops the later plugs, events and the component" do
        client = connect(Server, era: @era, scope: scope(halt: {:after_call, {:error, "No"}}))

        assert {:error, {:rpc, %{"code" => -32_600, "message" => "No"}}} =
                 call_tool(client, "whoami", %{"text" => "hi"})

        assert_received {:audit, "tools/call", %{arguments: _}}
        refute_received {:audit, "tools/call", %{result: _}}

        client =
          connect(Server,
            era: @era,
            scope: scope(halt: {:before_request, :not_found, "prompts/list"})
          )

        assert {:error, {:rpc, %{"code" => -32_601}}} = list_prompts(client)

        client =
          connect(Server,
            era: @era,
            scope: scope(halt: {:before_request, {:error, "Slow down"}, "tools/list"})
          )

        assert {:error, {:rpc, %{"message" => "Slow down"}}} = list_tools(client)

        client = connect(Server, era: @era, scope: scope(halt: {:before_read, :forbidden}))
        assert {:error, {:http, 403, _}} = read_resource(client, "note://1")

        client = connect(Server, era: @era, scope: scope(halt: {:after_get, {:tool_error, "x"}}))

        assert {:error, {:rpc, %{"code" => -32_600, "message" => "x"}}} =
                 get_prompt(client, "greet", %{"name" => "Rui"})

        client =
          connect(Server, era: @era, scope: scope(halt: {:after_list, {:error, "No list"}}))

        assert {:error, {:rpc, %{"message" => "No list"}}} = list_prompts(client)
        assert {:error, {:rpc, %{"message" => "No list"}}} = call_tool(client, "whoami")
      end

      test "a plug that raises or answers badly halts, logged, as an internal error" do
        for {key, event} <- [raise: :before_call, raise: :after_call, bad: :before_call] do
          client = connect(Server, era: @era, scope: scope([{key, event}]), reraise: false)

          log =
            capture_log(fn ->
              assert {:error, {:rpc, %{"code" => -32_603, "message" => "The request failed."}}} =
                       call_tool(client, "whoami", %{"text" => "hi"})
            end)

          assert log =~ "Sake.MiddlewareTest.Switch"
          assert log =~ to_string(event)
        end

        client = connect(Server, era: @era, scope: scope(bad: :after_list), reraise: false)

        assert capture_log(fn ->
                 assert {:error, {:rpc, %{"code" => -32_603}}} = list_tools(client)
               end) =~ "after_list"

        # With `reraise`, as for a component, the exception reaches the test.
        client = connect(Server, era: @era, scope: scope(raise: :before_get))

        assert_raise RuntimeError, "plug failed on before_get", fn ->
          get_prompt(client, "greet", %{"name" => "Rui"})
        end
      end
    end
  end

  describe "telemetry and tracing" do
    setup do
      test = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        id,
        [[:sake, :middleware, :halt], [:sake, :server, :request, :stop]],
        fn event, _measurements, meta, _ -> send(test, {:telemetry, event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "a halt is an event of its own, and the request's span still closes" do
      client = connect(Server, scope: scope(halt: {:before_call, {:secret, 42}}))
      assert {:error, {:rpc, %{"message" => "Request refused"}}} = call_tool(client, "whoami")

      assert_received {:telemetry, [:sake, :middleware, :halt],
                       %{
                         event: :before_call,
                         plug: Switch,
                         reason: {:secret, 42},
                         failed: false,
                         server: Server,
                         method: "tools/call",
                         component: "whoami",
                         era: :modern
                       }}

      assert_received {:telemetry, [:sake, :server, :request, :stop],
                       %{method: "tools/call", component: "whoami"}}
    end

    test "a failed plug is marked so" do
      client = connect(Server, scope: scope(raise: :after_list), reraise: false)

      capture_log(fn -> assert {:error, _} = read_resource(client, "note://1") end)

      assert_received {:telemetry, [:sake, :middleware, :halt],
                       %{event: :after_list, failed: true, method: "resources/read"}}
    end
  end

  describe "rounds and tasks" do
    for {era, rounds} <- [modern: 2, legacy: 1] do
      test "before_call runs on every request of a call that asks for input (#{era})" do
        client =
          connect(Server,
            era: unquote(era),
            scope: scope(),
            on_input: fn _params -> {:accept, %{"name" => "Rui"}} end
          )

        assert {:ok, %ToolResult{text: "Hello, Rui!"}} = call_tool(client, "confirm")

        # Each round of the modern protocol is a request of its own, which
        # starts with no assigns, the earlier round's not carried over.
        assert audits("tools/call", :params) == List.duplicate(%{}, unquote(rounds))
        assert length(audits("tools/call", :arguments)) == unquote(rounds)
      end
    end

    for era <- [:modern, :legacy] do
      test "a plug may ask the client before the call goes on (#{era})" do
        for {answer, expected} <- [{true, "hi for acme"}, {false, "Not confirmed."}] do
          client =
            connect(Server,
              era: unquote(era),
              scope: scope(confirm: true),
              on_input: fn _params -> {:accept, %{"ok" => answer}} end
            )

          assert {:ok, %ToolResult{text: text}} = call_tool(client, "whoami", %{"text" => "hi"})
          assert String.starts_with?(text, expected)
          assert_asked "elicitation/create", %{"message" => "Proceed?"}
        end
      end
    end

    test "a task's after_call runs when it ends, with the call's assigns" do
      client = connect(Server, scope: scope())
      assert {:ok, %ToolResult{text: "report for acme: [redacted]"}} = call_tool(client, "report")
      assert_received {:audit, "tools/call", %{arguments: %{tenant: "acme"}}}
      assert_receive {:audit, "tools/call", %{assigns: %{tenant: "acme"}, result: _}}
    end

    test "a halt in a task's after_call fails the task" do
      client = connect(Server, scope: scope(halt: {:after_call, {:error, "Withheld"}}))

      assert {:ok, {:task, %{"taskId" => id}}} = call_tool_async(client, "report")
      assert {:ok, %{"status" => "failed"} = task} = await_task(client, id)
      assert task["error"] == %{"code" => -32_600, "message" => "Withheld"}

      client = connect(Server, scope: scope(halt: {:after_call, {:tool_error, "Hidden"}}))
      assert {:ok, %ToolResult{is_error: true, text: "Hidden"}} = call_tool(client, "report")
    end
  end

  describe "on the wire" do
    defp modern_opts(scope, extra \\ []),
      do: ModernClient.opts([server: Server, scope: fn _ -> scope end] ++ extra)

    test "a forbidden halt is a 403, with no challenge on an endpoint without auth" do
      conn =
        ModernClient.post(modern_opts(scope(halt: {:before_call, :forbidden})), "tools/call", %{
          "name" => "whoami",
          "arguments" => %{}
        })

      assert conn.status == 403
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") == []

      assert %{"error" => %{"code" => -32_600, "message" => "Forbidden"}} =
               ModernClient.json(conn)

      # On an endpoint with authorization, a challenge: in the bearer tests.

      conn =
        ModernClient.post(
          modern_opts(scope(halt: {:before_request, {:error, "Slow down"}})),
          "tools/list"
        )

      assert conn.status == 200

      assert %{"error" => %{"code" => -32_600, "message" => "Slow down"}} =
               ModernClient.json(conn)
    end

    test "lists and reads that middleware shapes are private to the caller" do
      conn = ModernClient.post(modern_opts(scope()), "tools/list")
      assert %{"result" => %{"cacheScope" => "private"}} = ModernClient.json(conn)

      conn = ModernClient.post(modern_opts(scope()), "resources/read", %{"uri" => "note://1"})
      assert %{"result" => %{"cacheScope" => "private"}} = ModernClient.json(conn)

      opts = ModernClient.opts(server: Plain)
      conn = ModernClient.post(opts, "tools/list")
      assert %{"result" => %{"cacheScope" => "public"}} = ModernClient.json(conn)
      conn = ModernClient.post(opts, "resources/read", %{"uri" => "note://1"})
      assert %{"result" => %{"cacheScope" => "public"}} = ModernClient.json(conn)
    end

    test "a halt on a streamed call is the stream's error" do
      conn =
        ModernClient.post(modern_opts(scope(halt: {:before_call, :forbidden})), "tools/call", %{
          "name" => "whoami",
          "arguments" => %{},
          "_meta" => %{"progressToken" => "p"}
        })

      assert conn.status == 200

      assert [%{"error" => %{"code" => -32_600, "message" => "Forbidden"}}] =
               ModernClient.events(conn.resp_body)
    end

    test "a legacy subscription to a hidden resource is refused, and a forbidden batch item" do
      opts = ModernClient.opts(server: Server, scope: fn _ -> scope(plan: :free) end)
      session = LegacyClient.initialize(opts, "2025-11-25", %{})

      conn = LegacyClient.post(opts, session, "resources/subscribe", %{"uri" => "vault://keys"})

      assert %{"error" => %{"message" => "Resource does not support subscriptions: vault://keys"}} =
               LegacyClient.json(conn)

      conn = LegacyClient.post(opts, session, "resources/subscribe", %{"uri" => "note://1"})
      assert %{"result" => %{}} = LegacyClient.json(conn)

      opts =
        ModernClient.opts(
          server: Server,
          scope: fn _ -> scope(halt: {:before_request, :forbidden}) end
        )

      session = LegacyClient.initialize(opts, "2025-03-26", %{})

      conn =
        LegacyClient.raw(opts, session.id, [Sake.JSONRPC.request(1, "tools/list")], header: false)

      assert [%{"id" => 1, "error" => %{"message" => "Forbidden"}}] = LegacyClient.json(conn)
    end

    test "subscriptions/listen: before_request may refuse it, and a hidden resource is not followed" do
      conn =
        ModernClient.post(
          modern_opts(scope(halt: {:before_request, {:error, "Not now"}})),
          "subscriptions/listen",
          %{"notifications" => %{"toolsListChanged" => true}}
        )

      assert %{"error" => %{"message" => "Not now"}} = ModernClient.json(conn)

      ctx = Sake.Context.new(server: Server, scope: scope(plan: :free))

      params = %{
        "notifications" => %{"resourceSubscriptions" => ["vault://keys", "note://1", "x://y"]}
      }

      assert Sake.Plug.Stream.honoured(params, ctx) == %{
               "resourceSubscriptions" => ["note://1"]
             }

      params = %{"notifications" => %{"resourceSubscriptions" => ["vault://keys"]}}
      assert Sake.Plug.Stream.honoured(params, ctx) == %{}
    end
  end

  describe "declaring middleware" do
    test "init/1 runs once, when the server compiles, and the plugs keep their order" do
      assert %{after_list: [{Switch, :after_list}, {Plans, pro}]} = Server.__sake__(:middleware)
      assert MapSet.member?(pro, "export")
      assert Plain.__sake__(:middleware) == %{}

      assert [{Switch, :before_call}, {Tenant, []}, {Audit, []}, {Confirm, []}] =
               Server.__sake__(:middleware).before_call
    end

    test "an unknown event or a module without call/2 is refused at compile time" do
      assert_raise ArgumentError, ~r/:before_everything is not a middleware event/, fn ->
        defmodule Unknown do
          use Sake.Server, name: "x", version: "1"
          middleware :before_everything, [Audit]
        end
      end

      assert_raise ArgumentError, ~r/has no call\/2/, fn ->
        defmodule NoCall do
          use Sake.Server, name: "x", version: "1"
          middleware :before_call, [Sake.MiddlewareTest.Whoami]
        end
      end

      assert_raise ArgumentError, ~r/must be a module or \{module, opts\}/, fn ->
        defmodule Odd do
          use Sake.Server, name: "x", version: "1"
          middleware :before_call, ["audit"]
        end
      end
    end
  end

  test "every transport goes through the same middleware: stdio" do
    pipe = SakeTest.Pipe.start()
    test = self()

    {:ok, _} =
      Task.start_link(fn ->
        Sake.Stdio.run(Server, input: pipe, output: pipe, scope: scope(plan: :free, test: test))
      end)

    SakeTest.Pipe.push(
      pipe,
      Sake.JSONRPC.request(1, "tools/call", %{
        "name" => "export",
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      })
    )

    assert_receive {:pipe, ^pipe,
                    %{"id" => 1, "error" => %{"message" => "Unknown tool: export"}}},
                   2_000
  end
end

defmodule Sake.MiddlewareTraceTest do
  # Tests that capture spans run alone (see `SakeTest.Spans`).
  use ExUnit.Case, async: false

  import Sake.Test

  test "the request's span names the event and the plug" do
    SakeTest.Spans.capture()

    client =
      connect(Sake.MiddlewareTest.Server, scope: %{halt: {:before_call, :forbidden}})

    assert {:error, {:http, 403, _}} = call_tool(client, "whoami")

    %{"tools/call whoami" => span} = SakeTest.Spans.await(["tools/call whoami"])
    assert span.attributes["sake.middleware.event"] == "before_call"
    assert span.attributes["sake.middleware.plug"] == "Sake.MiddlewareTest.Switch"
  end
end
