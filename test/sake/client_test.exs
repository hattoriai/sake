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
        assert Enum.map(tools, & &1.name) == ["echo", "add", "slow", "confirm", "connect"]

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

      test "on_notification sees a call's progress", %{url: url} do
        parent = self()
        on_notification = fn method, params -> send(parent, {:notified, method, params}) end

        assert {:ok, session} = Client.connect(url, era: @era, on_notification: on_notification)

        assert {:ok, %{text: "counted to 2"}, _} =
                 Client.call_tool(session, "slow", %{"n" => 2, "delay_ms" => 0})

        assert_received {:notified, "notifications/progress", %{"progress" => 1, "total" => 2}}
        assert_received {:notified, "notifications/progress", %{"progress" => 2}}
      end
    end
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
                },
                %{
                  "name" => "twice",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{
                      "a" => %{"type" => "string", "x-mcp-header" => "Region"},
                      "b" => %{"type" => "string", "x-mcp-header" => "Region"}
                    }
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
    assert log =~ ~s("twice": invalid x-mcp-header \(duplicate names\))
  end

  test "a false argument is mirrored into its header like any other value" do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}/mcp"
    test = self()

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
                %{
                  "name" => "flags",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{
                      "verbose" => %{"type" => "boolean", "x-mcp-header" => "Verbose"},
                      "debug" => %{"type" => "boolean", "x-mcp-header" => "Debug"}
                    }
                  }
                }
              ]
            }

          "tools/call" ->
            send(test, {:headers, conn.req_headers})
            %{"content" => []}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => msg["id"], "result" => result})
      )
    end)

    {:ok, session} = Client.connect(url)
    {:ok, _tools, session} = Client.list_tools(session)
    {:ok, _result, _session} = Client.call_tool(session, "flags", %{"verbose" => false})

    assert_received {:headers, headers}
    assert {"mcp-param-verbose", "false"} in headers
    refute List.keymember?(headers, "mcp-param-debug", 0)
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
