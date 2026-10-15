defmodule Sake.SamplingTest do
  use ExUnit.Case, async: false

  alias SakeTest.{HTTP, ModernClient}

  @sampling %{"sampling" => %{}}
  @roots %{"roots" => %{}}

  defp call(opts, name, args, caps, extra \\ %{}) do
    opts
    |> ModernClient.post("tools/call", Map.merge(%{"name" => name, "arguments" => args}, extra),
      capabilities: caps
    )
    |> ModernClient.json()
  end

  defp retry(opts, name, args, caps, state, responses) do
    call(opts, name, args, caps, %{"inputResponses" => responses, "requestState" => state})
  end

  describe "sampling, modern" do
    test "input required with the sampling request, then the retry completes" do
      opts = ModernClient.opts()

      assert %{
               "result" => %{
                 "resultType" => "input_required",
                 "inputRequests" => %{"summary" => request},
                 "requestState" => state
               }
             } = call(opts, "summarize", %{"text" => "A long story."}, @sampling)

      assert request == %{
               "method" => "sampling/createMessage",
               "params" => %{
                 "messages" => [
                   %{
                     "role" => "user",
                     "content" => %{
                       "type" => "text",
                       "text" => "Summarize in one line:\n\nA long story."
                     }
                   }
                 ],
                 "maxTokens" => 100,
                 "systemPrompt" => "You write one-line summaries.",
                 "modelPreferences" => %{
                   "hints" => [%{"name" => "claude"}],
                   "speedPriority" => 0.8
                 }
               }
             }

      answer = %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => "A story, shortened."},
        "model" => "test-model",
        "stopReason" => "endTurn"
      }

      assert %{
               "result" => %{
                 "resultType" => "complete",
                 "isError" => false,
                 "content" => [%{"text" => "A story, shortened."}]
               }
             } =
               retry(opts, "summarize", %{"text" => "A long story."}, @sampling, state, %{
                 "summary" => answer
               })
    end

    test "a client without the capability gets {:error, :unsupported}" do
      assert %{
               "result" => %{
                 "isError" => true,
                 "content" => [%{"text" => "This tool needs a client that supports sampling."}]
               }
             } = call(ModernClient.opts(), "summarize", %{"text" => "x"}, %{})
    end

    test "an answer that is not a result object is an error, not a crash" do
      opts = ModernClient.opts()

      %{"result" => %{"requestState" => state}} =
        call(opts, "summarize", %{"text" => "x"}, @sampling)

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               retry(opts, "summarize", %{"text" => "x"}, @sampling, state, %{"summary" => 42})

      assert text == "The client did not summarize."
    end

    test "the result struct, content lists, and the options on the wire" do
      defmodule Ask do
        use Sake.Tool, name: "ask"

        @impl true
        def execute(%{}, ctx) do
          case Sake.Sampling.create_message(
                 ctx,
                 :q,
                 [
                   {:user, [Sake.Content.text("a"), Sake.Content.image("AAAA", "image/png")]},
                   {:assistant, "b"},
                   %{"role" => "user", "content" => %{"type" => "text", "text" => "c"}}
                 ],
                 max_tokens: 10,
                 temperature: 0.2,
                 stop_sequences: ["\n"],
                 include_context: :this_server,
                 metadata: %{"trace" => "1"},
                 model_preferences: %{"costPriority" => 1}
               ) do
            {:ok, result} -> {:ok, inspect(Map.delete(result, :raw))}
            {:error, reason} -> {:error, inspect(reason)}
          end
        end
      end

      defmodule AskServer do
        use Sake.Server, name: "ask", version: "1"
        tools [Ask]
      end

      opts = ModernClient.opts(server: AskServer)

      %{
        "result" => %{"inputRequests" => %{"q" => %{"params" => params}}, "requestState" => state}
      } =
        call(opts, "ask", %{}, @sampling)

      assert [
               %{"role" => "user", "content" => [%{"type" => "text"}, %{"type" => "image"}]},
               %{"role" => "assistant", "content" => %{"type" => "text", "text" => "b"}},
               %{"role" => "user", "content" => %{"text" => "c"}}
             ] = params["messages"]

      assert %{
               "maxTokens" => 10,
               "temperature" => 0.2,
               "stopSequences" => ["\n"],
               "includeContext" => "thisServer",
               "metadata" => %{"trace" => "1"},
               "modelPreferences" => %{"costPriority" => 1}
             } = params

      answer = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "one"},
          %{"type" => "tool_use", "id" => "t1", "name" => "x", "input" => %{}},
          %{"type" => "text", "text" => "two"}
        ],
        "model" => "m",
        "stopReason" => "toolUse"
      }

      assert %{"result" => %{"content" => [%{"text" => text}]}} =
               retry(opts, "ask", %{}, @sampling, state, %{"q" => answer})

      assert text =~ ~s(text: "one\\ntwo")
      assert text =~ ~s(model: "m")
      assert text =~ ~s(stop_reason: "toolUse")
      assert text =~ ~s(role: "assistant")
    end

    test "tools need sampling.tools; with it they go out as tool definitions" do
      defmodule WithTools do
        use Sake.Tool, name: "with_tools"

        @impl true
        def execute(%{}, ctx) do
          case Sake.Sampling.create_message(ctx, :t, [user: "weather?"],
                 max_tokens: 10,
                 tools: [SakeDev.Tools.Echo, %{"name" => "raw", "inputSchema" => %{}}],
                 tool_choice: :auto
               ) do
            {:ok, result} -> {:ok, result.text}
            {:error, reason} -> {:error, inspect(reason)}
          end
        end
      end

      defmodule ToolsServer do
        use Sake.Server, name: "tools", version: "1"
        tools [WithTools]
      end

      opts = ModernClient.opts(server: ToolsServer)

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => ":unsupported"}]}} =
               call(opts, "with_tools", %{}, @sampling)

      assert %{"result" => %{"inputRequests" => %{"t" => %{"params" => params}}}} =
               call(opts, "with_tools", %{}, %{"sampling" => %{"tools" => %{}}})

      assert [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}, %{"name" => "raw"}] =
               params["tools"]

      assert params["toolChoice"] == %{"mode" => "auto"}
    end

    test "max_tokens is required" do
      assert_raise ArgumentError, ~r/max_tokens/, fn ->
        Sake.Sampling.create_message(Sake.Context.new(), :k, [user: "x"], [])
      end
    end
  end

  describe "roots, modern" do
    test "input required with roots/list, then the retry lists them" do
      opts = ModernClient.opts()

      assert %{
               "result" => %{
                 "inputRequests" => %{
                   "roots" => %{"method" => "roots/list", "params" => %{}}
                 },
                 "requestState" => state
               }
             } = call(opts, "roots", %{}, @roots)

      roots = %{
        "roots" => [
          %{"uri" => "file:///work", "name" => "Work"},
          %{"uri" => "file:///tmp"},
          %{"name" => "no uri"}
        ]
      }

      assert %{
               "result" => %{
                 "content" => [%{"text" => "file:///work (Work)\nfile:///tmp (unnamed)"}]
               }
             } =
               retry(opts, "roots", %{}, @roots, state, %{"roots" => roots})

      assert %{"result" => %{"isError" => true}} =
               retry(opts, "roots", %{}, @roots, state, %{"roots" => %{"roots" => "nope"}})
    end

    test "a client without the capability gets {:error, :unsupported}" do
      assert %{
               "result" => %{
                 "isError" => true,
                 "content" => [%{"text" => "This tool needs a client that shares its roots."}]
               }
             } = call(ModernClient.opts(), "roots", %{}, %{"sampling" => %{}})
    end

    test "a capability another request declared does not answer for roots" do
      opts = ModernClient.opts()
      %{"result" => %{"requestState" => state}} = call(opts, "roots", %{}, @roots)

      # The same state and a forged answer, but the retry declares no roots:
      # the answer is never read.
      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               retry(opts, "roots", %{}, %{}, state, %{
                 "roots" => %{"roots" => [%{"uri" => "file:///"}]}
               })

      assert text =~ "shares its roots"
    end
  end

  describe "Sake.Input.all/2, modern" do
    test "every unanswered request goes out in one input-required result" do
      opts = ModernClient.opts(server: SakeDev.ConformanceServer)
      caps = Map.merge(@sampling, Map.merge(@roots, %{"elicitation" => %{}}))
      name = "test_input_required_result_multiple_inputs"

      assert %{"result" => %{"inputRequests" => requests, "requestState" => state}} =
               call(opts, name, %{}, caps)

      assert %{
               "user_name" => %{"method" => "elicitation/create"},
               "greeting" => %{"method" => "sampling/createMessage"},
               "client_roots" => %{"method" => "roots/list"}
             } = requests

      # A partial answer asks only for what is still missing.
      assert %{"result" => %{"inputRequests" => requests, "requestState" => state}} =
               retry(opts, name, %{}, caps, state, %{
                 "user_name" => %{"action" => "accept", "content" => %{"name" => "Ana"}}
               })

      assert Map.keys(requests) == ["client_roots", "greeting"]

      assert %{"result" => %{"resultType" => "complete", "content" => [%{"text" => text}]}} =
               retry(opts, name, %{}, caps, state, %{
                 "greeting" => %{
                   "role" => "assistant",
                   "content" => %{"type" => "text", "text" => "Hi"},
                   "model" => "m"
                 },
                 "client_roots" => %{"roots" => [%{"uri" => "file:///a"}]}
               })

      assert text == "Hi Ana (1 roots)"
    end

    test "requests the client cannot answer are left out" do
      opts = ModernClient.opts(server: SakeDev.ConformanceServer)

      assert %{"result" => %{"inputRequests" => requests}} =
               call(opts, "test_input_required_result_capabilities", %{}, @sampling)

      assert Map.keys(requests) == ["greeting"]
    end
  end

  describe "legacy (requests on the stream)" do
    setup do
      url = HTTP.start() <> "/mcp"
      %{url: url}
    end

    defp initialize(url, caps) do
      init =
        Req.post!(url,
          json:
            Sake.JSONRPC.request(0, "initialize", %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => caps,
              "clientInfo" => %{"name" => "t", "version" => "0"}
            }),
          headers: [{"accept", "application/json, text/event-stream"}]
        )

      [session] = init.headers["mcp-session-id"]

      [
        {"accept", "application/json, text/event-stream"},
        {"mcp-session-id", session},
        {"mcp-protocol-version", "2025-11-25"}
      ]
    end

    # Calls the tool on a stream, waits for the server's request, answers it
    # with `answer` (a result, or `{:error, error}`), and returns the events.
    defp ask_and_answer(url, headers, tool, args, answer) do
      body = Sake.JSONRPC.request(7, "tools/call", %{"name" => tool, "arguments" => args})

      task =
        Task.async(fn ->
          HTTP.sse(url, body, headers, fn events -> Enum.any?(events, &(&1["id"] == 7)) end)
        end)

      request_id = wait_for_request_id(3_000)

      message =
        case answer do
          {:error, error} -> %{"jsonrpc" => "2.0", "id" => request_id, "error" => error}
          result -> Sake.JSONRPC.result(request_id, result)
        end

      assert Req.post!(url, json: message, headers: headers).status == 202
      assert {:ok, events} = Task.await(task, 5_000)
      events
    end

    test "sampling: the server asks on the stream and continues with the answer", %{url: url} do
      headers = initialize(url, @sampling)

      answer = %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => "Short."},
        "model" => "m"
      }

      events = ask_and_answer(url, headers, "summarize", %{"text" => "Long."}, answer)

      assert [
               %{"method" => "sampling/createMessage", "params" => params},
               %{"id" => 7, "result" => %{"content" => [%{"text" => "Short."}]}}
             ] = events

      assert params["_meta"]["ai.hattori.sake/key"] == "summary"
      assert params["maxTokens"] == 100
    end

    test "sampling: a JSON-RPC error answer reaches the tool as {:error, error}", %{url: url} do
      headers = initialize(url, @sampling)
      error = %{"code" => -1, "message" => "User rejected sampling request"}
      events = ask_and_answer(url, headers, "summarize", %{"text" => "x"}, {:error, error})

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               List.last(events)

      assert text == "The client did not summarize."
    end

    test "roots: the server asks on the stream", %{url: url} do
      headers = initialize(url, @roots)
      roots = %{"roots" => [%{"uri" => "file:///w", "name" => "W"}]}
      events = ask_and_answer(url, headers, "roots", %{}, roots)

      assert [
               %{
                 "method" => "roots/list",
                 "params" => %{"_meta" => %{"ai.hattori.sake/key" => "roots"}}
               },
               %{"id" => 7, "result" => %{"content" => [%{"text" => "file:///w (W)"}]}}
             ] = events
    end

    test "roots/list_changed from the client is accepted", %{url: url} do
      headers = initialize(url, @roots)

      resp =
        Req.post!(url,
          json: Sake.JSONRPC.notification("notifications/roots/list_changed"),
          headers: headers
        )

      assert resp.status == 202
    end

    test "a client that declared neither gets a plain response, not a stream", %{url: url} do
      headers = initialize(url, %{})

      resp =
        Req.post!(url,
          json: Sake.JSONRPC.request(3, "tools/call", %{"name" => "roots", "arguments" => %{}}),
          headers: headers
        )

      assert ["application/json" <> _] = resp.headers["content-type"]
      assert %{"result" => %{"isError" => true}} = resp.body
    end
  end

  defp wait_for_request_id(timeout) do
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
          do: flunk("no server request was registered"),
          else: nil
    end)
  end
end
