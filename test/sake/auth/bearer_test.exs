defmodule Sake.Auth.BearerTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  alias SakeTest.ModernClient

  defp opts, do: ModernClient.opts(auth: true)

  defp call(token, extra \\ []) do
    ModernClient.post(opts(), "tools/list", %{},
      headers: [{"authorization", "Bearer " <> token}] ++ extra
    )
  end

  test "a valid token loads the subject, grants scopes and marks the cache private", %{
    config: config
  } do
    {access, _, _} =
      issue(config, %{scopes: ["issues:read"], resource: "http://www.example.com/mcp"})

    conn = call(access)
    assert conn.status == 200
    result = ModernClient.json(conn)["result"]

    assert Enum.map(result["tools"], & &1["name"]) == [
             "echo",
             "add",
             "confirm",
             "connect",
             "summarize",
             "roots",
             "export"
           ]

    assert result["cacheScope"] == "private"

    conn =
      ModernClient.post(opts(), "tools/call", %{"name" => "slow", "arguments" => %{"n" => 1}},
        headers: [{"authorization", "Bearer " <> access}]
      )

    assert conn.status == 403
    assert [challenge] = get_resp_header(conn, "www-authenticate")

    assert challenge ==
             ~s(Bearer error="insufficient_scope", scope="issues:write", resource_metadata="http://www.example.com/.well-known/oauth-protected-resource/mcp")
  end

  test "the scheme name is case-insensitive; the token follows one space", %{config: config} do
    {access, _, _} = issue(config, %{scopes: ["issues:read"]})

    for scheme <- ["Bearer", "bearer", "BEARER"] do
      conn =
        ModernClient.post(opts(), "tools/list", %{},
          headers: [{"authorization", scheme <> " " <> access}]
        )

      assert conn.status == 200, scheme
    end

    for header <- ["Bearer  " <> access, "Bearer" <> access, "Basic " <> access, "bearer "] do
      conn = ModernClient.post(opts(), "tools/list", %{}, headers: [{"authorization", header}])
      assert conn.status == 401, header
    end
  end

  test "missing, unknown, expired, revoked and wrong-audience tokens are 401 with a challenge", %{
    config: config
  } do
    conn = ModernClient.post(opts(), "tools/list")
    assert conn.status == 401

    assert [
             ~s(Bearer resource_metadata="http://www.example.com/.well-known/oauth-protected-resource/mcp", scope="issues:read issues:write")
           ] = get_resp_header(conn, "www-authenticate")

    assert %{"error" => %{"code" => -32_600, "message" => "Unauthorized"}, "id" => nil} =
             ModernClient.json(conn)

    assert call("nope").status == 401

    {access, _, %{access: a}} = issue(config, %{})
    {mod, state} = Sake.Auth.store(config)
    mod.revoke_token(state, a.id)
    assert call(access).status == 401

    {other, _, _} = issue(config, %{resource: "http://www.example.com/beta/mcp"})
    assert call(other).status == 401

    {expired, _, %{access: e}} = issue(config, %{})
    mod.put_token(state, %{e | expires_at: DateTime.add(DateTime.utc_now(), -1)})
    assert call(expired).status == 401
  end

  test "a token whose subject no longer exists is 401", %{config: config} do
    {access, _, _} = issue(config, %{subject_id: "gone"})
    assert call(access).status == 401
  end

  test "the canonical resource follows the mounted path" do
    conn =
      conn(:post, "/acme/mcp")
      |> Map.put(:scheme, :https)
      |> Map.put(:host, "App.Example")
      |> Map.put(:port, 443)

    assert Sake.Auth.Resource.canonical(conn, %{}) == "https://app.example/acme/mcp"
    conn = conn(:post, "/mcp/") |> Map.put(:port, 8443) |> Map.put(:scheme, :https)
    assert Sake.Auth.Resource.canonical(conn, %{}) == "https://www.example.com:8443/mcp"

    assert Sake.Auth.Resource.canonical(conn, %{resource: fn _ -> "https://fixed.example/mcp" end}) ==
             "https://fixed.example/mcp"

    assert Sake.Auth.Resource.metadata_url(conn(:post, "/acme/mcp")) ==
             "http://www.example.com/.well-known/oauth-protected-resource/acme/mcp"
  end

  test "the legacy era is protected too", %{config: config} do
    {access, _, _} = issue(config, %{scopes: ["issues:read", "issues:write"]})

    conn =
      SakeTest.LegacyClient.raw(
        opts(),
        nil,
        Sake.JSONRPC.request(0, "initialize", %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{}
        }),
        header: "2025-06-18"
      )

    assert conn.status == 401

    conn =
      conn(
        :post,
        "/mcp",
        JSON.encode!(
          Sake.JSONRPC.request(0, "initialize", %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{}
          })
        )
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("authorization", "Bearer " <> access)
      |> Sake.Plug.call(opts())

    assert conn.status == 200
  end
end
