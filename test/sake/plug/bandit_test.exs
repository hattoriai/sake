defmodule Sake.Plug.BanditTest do
  # Plug.Test does not check that a plug answers on the conn its last
  # Plug.Conn call returned; Bandit does, and refuses a stale one. Every
  # answer Sake gives after reading the body goes through a real server
  # here, and the next request on the same connection must still work.
  use ExUnit.Case, async: false

  alias SakeTest.HTTP

  @headers [
    {"accept", "application/json, text/event-stream"},
    {"content-type", "application/json"}
  ]

  setup do
    Application.ensure_all_started(:req)
    %{url: HTTP.start() <> "/mcp"}
  end

  defp post(url, body), do: Req.post!(url, body: body, headers: @headers, retry: false)

  test "errors after the body is read go out on the conn the read returned", %{url: url} do
    for {body, status, code} <- [
          {~s({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"inputResponses":null}}),
           400, -32_602},
          {~s({"jsonrpc":"2.0","id":2}), 400, -32_600},
          {~s({"jsonrpc":), 400, -32_700}
        ] do
      resp = post(url, body)
      assert resp.status == status
      assert %{"error" => %{"code" => ^code}} = resp.body
    end

    discover = %{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "server/discover",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    resp =
      Req.post!(url,
        json: discover,
        headers:
          @headers ++ [{"mcp-protocol-version", "2026-07-28"}, {"mcp-method", "server/discover"}],
        retry: false
      )

    assert resp.status == 200
    assert %{"result" => %{"supportedVersions" => [_ | _]}} = resp.body
  end

  test "a body over the limit gets 413", %{url: url} do
    resp = post(url, String.duplicate(" ", 4_000_001) <> "{}")
    assert resp.status == 413
  end
end
