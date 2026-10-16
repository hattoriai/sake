defmodule Sake.Proxy.CredentialsTest do
  # A proxy in front of an upstream protected by Sake's own authorization
  # server (the development router's `/acme/mcp`): with a fixed token, with
  # the client's own machine authorization, and with none.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Sake.Test

  alias Sake.Auth.Clients
  alias Sake.Client.ToolResult
  alias SakeTest.HTTP

  defmodule Fixed do
    use Sake.Proxy, name: "fixed", version: "1", upstream: "http://127.0.0.1:1/mcp"
  end

  defmodule Machine do
    use Sake.Proxy, name: "machine", version: "1", upstream: "http://127.0.0.1:1/mcp"
  end

  setup do
    base = HTTP.start(SakeDev.Router)

    start_supervised!(
      {Sake,
       auth: [
         subject: SakeDev.Subject,
         issuer: base,
         allow_insecure: true,
         servers: [SakeDev.Server],
         resources: ["/mcp", "/acme/mcp", "/beta/mcp"],
         store: {Sake.Auth.Store.ETS, []}
       ],
       secret_key_base: SakeTest.ModernClient.secret(),
       streams: false,
       tasks: false}
    )

    %{url: base <> "/acme/mcp", config: Sake.Auth.config()}
  end

  test "a fixed token", %{url: url} do
    token = access_token(subject: "u1", scopes: ["issues:read"], resource: url)

    start_supervised!(
      {Fixed, upstream: url, connect: [headers: [{"authorization", "Bearer " <> token}]]}
    )

    client = connect(Fixed)
    assert {:ok, tools} = list_tools(client)
    assert "echo" in Enum.map(tools, & &1.name)
    assert {:ok, %ToolResult{text: "hi"}} = call_tool(client, "echo", %{"text" => "hi"})

    # `slow` needs issues:write, which the token does not have: the
    # upstream does not list it, so neither does the proxy.
    refute "slow" in Enum.map(tools, & &1.name)

    assert {:error, {:rpc, %{"message" => "Unknown tool: slow"}}} =
             call_tool(client, "slow", %{"n" => 1, "delay_ms" => 0})
  end

  test "the client's own machine authorization", %{url: url, config: config} do
    {:ok, machine, secret} =
      Clients.create(config, %{
        name: "Gateway",
        grant_types: ["client_credentials"],
        confidential: true,
        scopes: ["issues:read", "issues:write"]
      })

    auth = [grant: :client_credentials, client_id: machine.id, client_secret: secret]
    start_supervised!({Machine, upstream: url, connect: [auth: auth]})

    client = connect(Machine)

    assert {:ok, %ToolResult{text: "counted to 1"}} =
             call_tool(client, "slow", %{"n" => 1, "delay_ms" => 0})
  end

  test "no credentials: the upstream refuses, and the proxy lists nothing", %{url: url} do
    start_supervised!({Fixed, upstream: url})
    client = connect(Fixed)

    log = capture_log(fn -> assert {:ok, []} = list_tools(client) end)
    assert log =~ "could not list the upstream's tools"
  end
end
