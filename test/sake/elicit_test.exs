defmodule Sake.ElicitTest do
  use ExUnit.Case, async: false

  alias SakeTest.{HTTP, ModernClient}

  @caps %{"elicitation" => %{}}

  describe "modern (multi round-trip)" do
    test "input required, then the retry completes" do
      opts = ModernClient.opts()

      conn =
        ModernClient.post(opts, "tools/call", %{"name" => "confirm", "arguments" => %{}},
          capabilities: @caps
        )

      assert %{
               "result" => %{
                 "resultType" => "input_required",
                 "inputRequests" => %{"who" => req},
                 "requestState" => state
               }
             } = ModernClient.json(conn)

      assert req == %{
               "method" => "elicitation/create",
               "params" => %{
                 "mode" => "form",
                 "message" => "Who should be greeted?",
                 "requestedSchema" => %{
                   "type" => "object",
                   "properties" => %{"name" => %{"type" => "string"}},
                   "required" => ["name"]
                 }
               }
             }

      conn =
        ModernClient.post(
          opts,
          "tools/call",
          %{
            "name" => "confirm",
            "arguments" => %{},
            "inputResponses" => %{
              "who" => %{"action" => "accept", "content" => %{"name" => "Rui"}}
            },
            "requestState" => state
          },
          capabilities: @caps,
          id: 2
        )

      assert %{
               "result" => %{
                 "resultType" => "complete",
                 "content" => [%{"text" => "Hello, Rui!"}]
               }
             } = ModernClient.json(conn)

      conn =
        ModernClient.post(
          opts,
          "tools/call",
          %{
            "name" => "confirm",
            "arguments" => %{},
            "inputResponses" => %{"who" => %{"action" => "decline"}},
            "requestState" => state
          },
          capabilities: @caps,
          id: 3
        )

      assert %{"result" => %{"content" => [%{"text" => "No greeting then."}]}} =
               ModernClient.json(conn)
    end

    test "the state is bound to the tool, the arguments and the principal" do
      opts = ModernClient.opts()

      conn =
        ModernClient.post(
          opts,
          "tools/call",
          %{"name" => "confirm", "arguments" => %{"greeting" => "Hi"}},
          capabilities: @caps
        )

      state = ModernClient.json(conn)["result"]["requestState"]

      conn =
        ModernClient.post(
          opts,
          "tools/call",
          %{
            "name" => "confirm",
            "arguments" => %{"greeting" => "Yo"},
            "inputResponses" => %{"who" => %{"action" => "accept", "content" => %{"name" => "x"}}},
            "requestState" => state
          },
          capabilities: @caps
        )

      assert %{"error" => %{"code" => -32_602, "message" => "Invalid request state"}} =
               ModernClient.json(conn)

      conn =
        ModernClient.post(
          opts,
          "tools/call",
          %{
            "name" => "confirm",
            "arguments" => %{"greeting" => "Hi"},
            "inputResponses" => %{},
            "requestState" => state <> "x"
          },
          capabilities: @caps
        )

      assert %{"error" => %{"code" => -32_602}} = ModernClient.json(conn)

      scoped = ModernClient.opts(scope: fn conn -> conn.assigns[:who] end)

      conn =
        ModernClient.post(
          scoped,
          "tools/call",
          %{
            "name" => "confirm",
            "arguments" => %{"greeting" => "Hi"},
            "inputResponses" => %{},
            "requestState" => state
          },
          capabilities: @caps,
          headers: []
        )

      assert conn.status == 200
    end

    test "a retry with the answer missing asks again; a client without the capability gets a tool error" do
      opts = ModernClient.opts()

      conn =
        ModernClient.post(opts, "tools/call", %{"name" => "confirm", "arguments" => %{}},
          capabilities: @caps
        )

      state = ModernClient.json(conn)["result"]["requestState"]

      conn =
        ModernClient.post(
          opts,
          "tools/call",
          %{
            "name" => "confirm",
            "arguments" => %{},
            "inputResponses" => %{},
            "requestState" => state
          },
          capabilities: @caps
        )

      assert %{"result" => %{"resultType" => "input_required"}} = ModernClient.json(conn)

      conn = ModernClient.post(opts, "tools/call", %{"name" => "confirm", "arguments" => %{}})

      assert %{
               "result" => %{
                 "isError" => true,
                 "content" => [%{"text" => "This tool needs a client that supports elicitation."}]
               }
             } = ModernClient.json(conn)
    end

    test "url mode" do
      opts = ModernClient.opts()

      conn =
        ModernClient.post(opts, "tools/call", %{"name" => "connect", "arguments" => %{}},
          capabilities: @caps
        )

      assert %{
               "result" => %{
                 "inputRequests" => %{
                   "page" => %{
                     "params" => %{
                       "mode" => "url",
                       "url" => "https://example.com/connect",
                       "message" => _
                     }
                   }
                 },
                 "requestState" => state
               }
             } = ModernClient.json(conn)

      conn =
        ModernClient.post(
          opts,
          "tools/call",
          %{
            "name" => "connect",
            "arguments" => %{},
            "inputResponses" => %{"page" => %{"action" => "accept"}},
            "requestState" => state
          },
          capabilities: @caps
        )

      assert %{"result" => %{"content" => [%{"text" => "Connected."}]}} = ModernClient.json(conn)
    end

    test "inputResponses without a request state are rejected" do
      conn =
        ModernClient.post(
          ModernClient.opts(),
          "tools/call",
          %{
            "name" => "confirm",
            "arguments" => %{},
            "inputResponses" => %{
              "who" => %{"action" => "accept", "content" => %{"name" => "Mallory"}}
            }
          },
          capabilities: @caps
        )

      assert %{"error" => %{"code" => -32_602, "message" => "Missing request state"}} =
               ModernClient.json(conn)
    end

    test "a resource can elicit and complete on retry" do
      defmodule Secret do
        use Sake.Resource, uri: "secret://{id}", name: "secret", mime_type: "text/plain"

        def read(%{id: id}, ctx) do
          case Sake.Elicit.form(ctx, :pin, "PIN?", %{
                 "type" => "object",
                 "properties" => %{"pin" => %{"type" => "string"}}
               }) do
            {:ok, %{"pin" => pin}} -> {:ok, "secret #{id} unlocked with #{pin}"}
            _ -> {:error, "no pin"}
          end
        end
      end

      defmodule SecretServer do
        use Sake.Server, name: "s", version: "1"
        resources [Secret]
      end

      opts = ModernClient.opts(server: SecretServer)

      conn =
        ModernClient.post(opts, "resources/read", %{"uri" => "secret://7"}, capabilities: @caps)

      assert %{
               "result" => %{
                 "resultType" => "input_required",
                 "inputRequests" => %{"pin" => _},
                 "requestState" => state
               }
             } = ModernClient.json(conn)

      conn =
        ModernClient.post(
          opts,
          "resources/read",
          %{
            "uri" => "secret://7",
            "inputResponses" => %{
              "pin" => %{"action" => "accept", "content" => %{"pin" => "1234"}}
            },
            "requestState" => state
          },
          capabilities: @caps,
          id: 2
        )

      assert %{"result" => %{"contents" => [%{"text" => "secret 7 unlocked with 1234"}]}} =
               ModernClient.json(conn)

      conn =
        ModernClient.post(
          opts,
          "resources/read",
          %{
            "uri" => "secret://8",
            "inputResponses" => %{
              "pin" => %{"action" => "accept", "content" => %{"pin" => "1234"}}
            },
            "requestState" => state
          },
          capabilities: @caps,
          id: 3
        )

      assert %{"error" => %{"code" => -32_602, "message" => "Invalid request state"}} =
               ModernClient.json(conn)
    end
  end

  describe "legacy (request on the stream)" do
    test "the server asks on the response stream and continues after the client's POSTed answer" do
      url = HTTP.start()

      init =
        Req.post!(url <> "/mcp",
          json:
            Sake.JSONRPC.request(0, "initialize", %{
              "protocolVersion" => "2025-06-18",
              "capabilities" => @caps,
              "clientInfo" => %{"name" => "t", "version" => "0"}
            }),
          headers: [{"accept", "application/json, text/event-stream"}]
        )

      [session] = init.headers["mcp-session-id"]

      headers = [
        {"accept", "application/json, text/event-stream"},
        {"mcp-session-id", session},
        {"mcp-protocol-version", "2025-06-18"}
      ]

      body = Sake.JSONRPC.request(5, "tools/call", %{"name" => "confirm", "arguments" => %{}})

      task =
        Task.async(fn ->
          HTTP.sse(url <> "/mcp", body, headers, fn events ->
            Enum.any?(events, &(&1["id"] == 5))
          end)
        end)

      request_id = wait_for_elicit_id(3_000)

      answer = %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "result" => %{"action" => "accept", "content" => %{"name" => "Ana"}}
      }

      assert Req.post!(url <> "/mcp", json: answer, headers: headers).status == 202
      assert {:ok, events} = Task.await(task, 5_000)

      assert [
               %{"id" => ^request_id, "method" => "elicitation/create"} = elicit_event,
               %{"id" => 5, "result" => %{"content" => [%{"text" => "Hello, Ana!"}]}}
             ] = events

      assert get_in(elicit_event, ["params", "_meta", "ai.hattori.sake/key"]) == "who"
    end
  end

  defp wait_for_elicit_id(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      Process.sleep(20)
      Registry.select(Sake.Plug.Streams, [{{{:request, :"$1"}, :_, :_}, [], [:"$1"]}])
    end)
    |> Enum.find_value(fn
      [id | _] ->
        id

      [] ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("no elicitation request was registered"),
          else: nil
    end)
  end
end
