defmodule Sake.ClientTest do
  use ExUnit.Case, async: false

  alias Sake.Client
  alias SakeTest.HTTP

  setup do
    %{url: HTTP.start() <> "/mcp"}
  end

  for era <- [:modern, :legacy] do
    describe "#{era}" do
      @era era

      test "connect, discover, tools, call, resources, prompts, completion, ping, close", %{
        url: url
      } do
        assert {:ok, session} = Client.connect(url, era: @era)
        assert session.era == @era
        assert session.server_info["name"] == "sake-dev"
        assert {:ok, tools, session} = Client.list_tools(session)

        assert Enum.map(tools, & &1.name) == [
                 "echo",
                 "add",
                 "slow",
                 "confirm",
                 "connect",
                 "summarize",
                 "roots"
               ]

        assert %Sake.Tool.Spec{headers: %{"Precision" => ["precision"]}} =
                 Enum.find(tools, &(&1.name == "add"))

        assert {:ok, result, session} =
                 Client.call_tool(session, "add", %{"a" => 1, "b" => 2, "precision" => 1})

        assert result.structured == %{"sum" => 3.0} and result.is_error == false and
                 result.text =~ "3.0"

        assert [%Sake.Content{type: :text}] = result.content

        assert {:ok, result, session} =
                 Client.call_tool(session, "slow", %{"n" => 2, "delay_ms" => 0})

        assert result.text == "counted to 2"

        assert {:ok, %{is_error: true, text: text}, session} =
                 Client.call_tool(session, "add", %{"a" => "x"})

        assert text =~ "Invalid arguments"

        assert {:error, {:rpc, %{"code" => -32_602}}, session} =
                 Client.call_tool(session, "nope", %{})

        assert {:ok, resources, session} = Client.list_resources(session)
        assert Enum.map(resources, & &1["uri"]) == ["dev://readme", "issue://1", "issue://2"]

        assert {:ok, [%Sake.Content{type: :resource, uri: "issue://1", text: text}], session} =
                 Client.read_resource(session, "issue://1")

        assert JSON.decode!(text)["id"] == "1"

        assert {:ok, [%{"uriTemplate" => "issue://{id}"}], session} =
                 Client.list_resource_templates(session)

        assert {:ok, [%{"name" => "triage"}], session} = Client.list_prompts(session)

        assert {:ok, %{"messages" => [%{"role" => "user"}]}, session} =
                 Client.get_prompt(session, "triage", %{"id" => "1"})

        assert {:ok, %{"values" => ["direct"]}, session} =
                 Client.complete(session, {:prompt, "triage"}, "tone", "d")

        assert {:ok, session} = Client.ping(session)
        assert :ok = Client.close(session)
      end

      test "elicitation through on_input", %{url: url} do
        parent = self()

        on_input = fn requests, _session ->
          send(parent, {:asked, requests})

          Map.new(requests, fn {key, _req} ->
            {key, %{"action" => "accept", "content" => %{"name" => "Rui"}}}
          end)
        end

        assert {:ok, session} = Client.connect(url, era: @era, on_input: on_input)
        assert {:ok, %{text: "Hello, Rui!"}, _} = Client.call_tool(session, "confirm", %{})
        assert_receive {:asked, %{"who" => %{"method" => "elicitation/create"}}}
      end

      test "without on_input the tool sees a cancel", %{url: url} do
        assert {:ok, session} =
                 Client.connect(url, era: @era, capabilities: %{"elicitation" => %{}})

        assert {:ok, %{is_error: true, text: "Cancelled."}, _} =
                 Client.call_tool(session, "confirm", %{})
      end

      test "sampling through sampling:", %{url: url} do
        parent = self()

        sampling = fn params, _session ->
          send(parent, {:sampled, params})

          {:ok,
           %{
             "role" => "assistant",
             "content" => %{"type" => "text", "text" => "Short."},
             "model" => "test-model"
           }}
        end

        assert {:ok, session} = Client.connect(url, era: @era, sampling: sampling)
        assert session.capabilities == %{"sampling" => %{}}

        assert {:ok, %{text: "Short.", is_error: false}, _} =
                 Client.call_tool(session, "summarize", %{"text" => "Long."})

        assert_receive {:sampled, %{"maxTokens" => 100, "messages" => [%{"role" => "user"}]}}
      end

      test "roots through roots:, as a list or a function", %{url: url} do
        roots = [%{"uri" => "file:///work", "name" => "Work"}]
        assert {:ok, session} = Client.connect(url, era: @era, roots: roots)
        assert session.capabilities == %{"roots" => %{"listChanged" => false}}

        assert {:ok, %{text: "file:///work (Work)"}, _} = Client.call_tool(session, "roots", %{})

        assert {:ok, session} =
                 Client.connect(url,
                   era: @era,
                   roots: fn _session -> [%{"uri" => "file:///f"}] end
                 )

        assert {:ok, %{text: "file:///f (unnamed)"}, _} = Client.call_tool(session, "roots", %{})
      end
    end
  end

  test "on a legacy stream, a sampling error goes back as a JSON-RPC error", %{url: url} do
    sampling = fn _params, _session -> {:error, %{"code" => -1, "message" => "Declined"}} end
    assert {:ok, session} = Client.connect(url, era: :legacy, sampling: sampling)

    assert {:ok, %{is_error: true, text: "The client did not summarize."}, _} =
             Client.call_tool(session, "summarize", %{"text" => "x"})
  end

  test "a legacy server request nothing can answer gets an error; elicitation a cancel" do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}/mcp"
    parent = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      msg = JSON.decode!(body)

      case msg do
        %{"method" => "initialize"} ->
          json(conn, msg["id"], %{"protocolVersion" => "2025-11-25", "capabilities" => %{}})

        %{"method" => "notifications/initialized"} ->
          Plug.Conn.resp(conn, 202, "")

        %{"method" => "tools/call"} ->
          requests = [
            Sake.JSONRPC.request("s1", "sampling/createMessage", %{"messages" => []}),
            Sake.JSONRPC.request("r1", "roots/list", %{}),
            Sake.JSONRPC.request("e1", "elicitation/create", %{"message" => "?"}),
            Sake.JSONRPC.request("p1", "ping", %{}),
            Sake.JSONRPC.result(msg["id"], %{"content" => []})
          ]

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, Enum.map_join(requests, &"data: #{JSON.encode!(&1)}\n\n"))

        answer ->
          send(parent, {:answer, answer})
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    assert {:ok, session} = Client.connect(url, era: :legacy)
    assert {:ok, %{content: []}, _} = Client.call_tool(session, "x", %{})

    assert_receive {:answer, %{"id" => "s1", "error" => %{"code" => -32_601}}}
    assert_receive {:answer, %{"id" => "r1", "error" => %{"code" => -32_601}}}
    assert_receive {:answer, %{"id" => "e1", "result" => %{"action" => "cancel"}}}
    assert_receive {:answer, %{"id" => "p1", "error" => %{"code" => -32_601}}}
  end

  defp json(conn, id, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end

  test "a bad tool definition from a server is dropped with a warning" do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}/mcp"

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      msg = JSON.decode!(body)

      result =
        case msg["method"] do
          "server/discover" ->
            %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{"tools" => %{}}}

          "tools/list" ->
            %{
              "tools" => [
                %{"name" => "ok", "inputSchema" => %{"type" => "object"}},
                %{
                  "name" => "bad",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{"n" => %{"type" => "number", "x-mcp-header" => "N"}}
                  }
                }
              ]
            }
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => msg["id"], "result" => result})
      )
    end)

    {:ok, session} = Client.connect(url)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, [%{name: "ok"}], _} = Client.list_tools(session)
      end)

    assert log =~ "bad" and log =~ "x-mcp-header"
  end

  test "pagination stops when a server keeps returning the same cursor" do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}/mcp"

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      msg = JSON.decode!(body)

      result =
        case msg["method"] do
          "server/discover" ->
            %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{"tools" => %{}}}

          "tools/list" ->
            %{"tools" => [], "nextCursor" => "same-cursor"}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => msg["id"], "result" => result})
      )
    end)

    {:ok, session} = Client.connect(url)
    assert {:error, :pagination_loop, _session} = Client.list_tools(session)
  end
end
