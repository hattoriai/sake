defmodule Sake.Client.StdioTest do
  use ExUnit.Case, async: true

  alias Sake.Client

  # A script from test/support/stdio, run by `elixir` with this build's
  # code paths, so the server is the compiled test code itself.
  defp script(name, args \\ []) do
    paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])

    {:stdio, System.find_executable("elixir"),
     paths ++ [Path.expand("../../support/stdio/#{name}.exs", __DIR__) | args]}
  end

  for era <- [:modern, :legacy] do
    describe "#{era}" do
      @era era

      test "connect, list and call tools, read a resource, close" do
        assert {:ok, session} = Client.connect(script("server"), era: @era)
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
                 "roots",
                 "export",
                 "issue_board"
               ]

        assert {:ok, %{text: "héllo ✓"}, session} =
                 Client.call_tool(session, "echo", %{"text" => "héllo ✓"})

        assert {:ok, %{structured: %{"sum" => 3}}, session} =
                 Client.call_tool(session, "add", %{"a" => 1, "b" => 2})

        assert {:error, {:rpc, %{"code" => -32_602}}, session} =
                 Client.call_tool(session, "nope", %{})

        assert {:ok, [%Sake.Content{uri: "dev://readme"}], session} =
                 Client.read_resource(session, "dev://readme")

        assert {:ok, session} = Client.ping(session)
        assert :ok = Client.close(session)
        refute Process.alive?(session.stdio)
      end

      test "sampling: and roots: answer the server's requests" do
        sampling = fn _params, _session ->
          {:ok,
           %{
             "role" => "assistant",
             "content" => %{"type" => "text", "text" => "Short."},
             "model" => "m"
           }}
        end

        assert {:ok, session} =
                 Client.connect(script("server"),
                   era: @era,
                   sampling: sampling,
                   roots: [%{"uri" => "file:///w", "name" => "W"}]
                 )

        assert {:ok, %{text: "Short."}, session} =
                 Client.call_tool(session, "summarize", %{"text" => "Long."})

        assert {:ok, %{text: "file:///w (W)"}, session} = Client.call_tool(session, "roots", %{})
        assert :ok = Client.close(session)
      end

      test "a task tool: followed to its result on modern, run synchronously on legacy" do
        on_input = fn requests, _session ->
          Map.new(requests, fn {key, _} ->
            {key, %{"action" => "accept", "content" => %{"format" => "json"}}}
          end)
        end

        assert {:ok, session} = Client.connect(script("server"), era: @era, on_input: on_input)

        assert {:ok, %{text: "Exported 2 issues as json."}, session} =
                 Client.call_tool(session, "export", %{"n" => 2, "delay_ms" => 0})

        assert :ok = Client.close(session)
      end

      test "on_input answers an elicitation" do
        on_input = fn requests, _session ->
          Map.new(requests, fn {key, _request} ->
            {key, %{"action" => "accept", "content" => %{"name" => "Ana"}}}
          end)
        end

        {:ok, session} = Client.connect(script("server"), era: @era, on_input: on_input)

        assert {:ok, %{text: "Hello, Ana!"}, session} =
                 Client.call_tool(session, "confirm", %{})

        Client.close(session)
      end

      test "on_notification sees a call's progress" do
        test = self()
        on_notification = fn method, params -> send(test, {:notified, method, params}) end

        {:ok, session} =
          Client.connect(script("server"), era: @era, on_notification: on_notification)

        assert {:ok, %{text: "counted to 2"}, session} =
                 Client.call_tool(session, "slow", %{"n" => 2, "delay_ms" => 0})

        assert_received {:notified, "notifications/progress", %{"progress" => 1, "total" => 2}}
        assert_received {:notified, "notifications/progress", %{"progress" => 2}}
        Client.close(session)
      end
    end
  end

  describe "era probing" do
    test "a Sake server answers server/discover: modern" do
      assert {:ok, %{era: :modern} = session} = Client.connect(script("server"))
      Client.close(session)
    end

    test "a legacy server that answers the probe with any error: initialize" do
      assert {:ok, %{era: :legacy} = session} =
               Client.connect(script("foreign", ["error"]), stderr: :ignore)

      assert session.server_info["name"] == "foreign"
      assert {:ok, [%{name: "t"}], session} = Client.list_tools(session)
      Client.close(session)
    end

    test "a legacy server that does not answer the probe: initialize after the timeout" do
      assert {:ok, %{era: :legacy} = session} =
               Client.connect(script("foreign", ["silent"]), probe_timeout: 300)

      assert {:ok, [%{name: "t"}], session} = Client.list_tools(session)
      Client.close(session)
    end
  end

  describe "the process" do
    test "close/1 kills a server that does not exit when its input closes" do
      {:ok, session} =
        Client.connect(script("foreign", ["stubborn"]),
          era: :legacy,
          close_timeout: 200,
          stderr: :ignore
        )

      %{os_pid: os_pid} = :sys.get_state(session.stdio)
      started = System.monotonic_time(:millisecond)
      assert :ok = Client.close(session)
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert {_, 1} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    end

    test "a command that does not exist, and a server that exits at once" do
      assert {:error, :enoent} = Client.connect({:stdio, "sake-no-such-command", []})
      assert {:error, :closed} = Client.connect({:stdio, "true", []})
    end

    test "env: and cd: reach the server" do
      dir = File.cwd!() |> Path.join("test")

      reply =
        ~S[read line; echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"'"$SAKE_TEST:$(pwd)"'"}}']

      assert {:error, {:rpc, %{"message" => message}}} =
               Client.connect({:stdio, "sh", ["-c", reply]},
                 era: :modern,
                 env: %{"SAKE_TEST" => "x"},
                 cd: dir
               )

      assert message == "x:" <> dir
    end
  end
end
