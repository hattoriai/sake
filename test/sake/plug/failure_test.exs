defmodule Sake.Plug.FailureTest do
  # A component that fails never tells the client why: the error is a
  # generic -32603 with an ID, and the detail goes only to the log
  # (issue #34).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SakeTest.{LegacyClient, ModernClient, Pipe}

  @marker "synthetic-db-password=DO_NOT_DISCLOSE"

  defmodule Fail do
    @moduledoc false
    @marker "synthetic-db-password=DO_NOT_DISCLOSE"

    def fail("raise"), do: raise(@marker)
    def fail("throw"), do: throw({:secret, @marker})
    def fail("exit"), do: exit({:secret, @marker})
    # An exit signal no `catch` sees: the process running the request dies.
    def fail("kill"), do: Process.exit(self(), {:secret, @marker})
  end

  defmodule Resource do
    use Sake.Resource, uri: "fail://{mode}", name: "fail"
    alias Sake.Plug.FailureTest.Fail

    @impl true
    def read(%{mode: mode}, _ctx), do: Fail.fail(mode)

    @impl true
    def complete("mode", partial, _ctx), do: Fail.fail(partial)
  end

  defmodule Prompt do
    use Sake.Prompt, name: "fail"
    alias Sake.Plug.FailureTest.Fail
    arg :mode, :string, required: true

    @impl true
    def get(%{mode: mode}, _ctx), do: Fail.fail(mode)

    @impl true
    def complete("mode", partial, _ctx), do: Fail.fail(partial)
  end

  defmodule Server do
    use Sake.Server, name: "fail", version: "1"
    resources [Resource]
    prompts [Prompt]
  end

  defp requests(mode) do
    [
      {"resources/read", %{"uri" => "fail://#{mode}"}},
      {"prompts/get", %{"name" => "fail", "arguments" => %{"mode" => mode}}},
      {"completion/complete",
       %{
         "ref" => %{"type" => "ref/prompt", "name" => "fail"},
         "argument" => %{"name" => "mode", "value" => mode}
       }},
      {"completion/complete",
       %{
         "ref" => %{"type" => "ref/resource", "uri" => "fail://{mode}"},
         "argument" => %{"name" => "mode", "value" => mode}
       }}
    ]
  end

  defp opts, do: ModernClient.opts(server: Server)

  # The error the client got: generic, with an ID the log names next to the
  # detail; the marker nowhere in what the client saw.
  defp assert_generic(error, body, log) do
    assert %{"code" => -32_603, "message" => "The request failed.", "data" => %{"errorId" => id}} =
             error

    refute body =~ "DO_NOT_DISCLOSE"
    assert log =~ "(error #{id})" and log =~ @marker
  end

  test "modern JSON responses" do
    for mode <- ~w(raise throw exit), {method, params} <- requests(mode) do
      {conn, log} = with_log(fn -> ModernClient.post(opts(), method, params) end)
      assert conn.status == 200, "#{method} #{mode}"
      assert_generic(ModernClient.json(conn)["error"], conn.resp_body, log)
    end
  end

  test "modern SSE responses" do
    for mode <- ~w(raise throw exit), {method, params} <- requests(mode) do
      {conn, log} =
        with_log(fn ->
          ModernClient.post(opts(), method, params, meta: %{"progressToken" => 1})
        end)

      assert [%{"error" => error}] = ModernClient.events(conn.resp_body), "#{method} #{mode}"
      assert_generic(error, conn.resp_body, log)
    end
  end

  test "legacy JSON responses" do
    session = LegacyClient.initialize(opts(), "2025-06-18")

    for mode <- ~w(raise throw exit), {method, params} <- requests(mode) do
      {conn, log} = with_log(fn -> LegacyClient.post(opts(), session, method, params) end)
      assert_generic(LegacyClient.json(conn)["error"], conn.resp_body, log)
    end
  end

  test "stdio, the handler's process killed included" do
    pipe = Pipe.start()
    test = self()
    {:ok, _} = Task.start_link(fn -> Sake.Stdio.run(Server, input: pipe, output: pipe) end)

    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    for {mode, n} <- Enum.with_index(~w(raise throw exit kill)),
        {{method, params}, m} <- Enum.with_index(requests(mode)) do
      id = n * 10 + m

      log =
        capture_log(fn ->
          Pipe.push(pipe, Sake.JSONRPC.request(id, method, Map.put(params, "_meta", meta)))
          assert_receive {:pipe, ^pipe, %{"id" => ^id, "error" => error} = response}, 2_000
          send(test, {:response, error, response})
        end)

      assert_received {:response, error, response}
      assert_generic(error, JSON.encode!(response), log)
    end
  end
end
