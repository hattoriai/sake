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
             "export",
             "issue_board"
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

    # A call that would stream, because it asks for progress, is refused
    # the same way rather than on a stream.
    {none, _, _} = issue(config, %{scopes: []})

    for {token, method, params} <- [
          {access, "tools/call", %{"name" => "slow", "arguments" => %{"n" => 1}}},
          {none, "resources/read", %{"uri" => "issue://1"}}
        ] do
      conn =
        ModernClient.post(opts(), method, params,
          headers: [{"authorization", "Bearer " <> token}],
          meta: %{"progressToken" => 1}
        )

      assert conn.status == 403

      assert [~s(Bearer error="insufficient_scope", scope=) <> _] =
               get_resp_header(conn, "www-authenticate")
    end
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

    # RFC 9449 §7.1: a server that takes DPoP challenges for both schemes.
    assert [
             ~s(Bearer resource_metadata="http://www.example.com/.well-known/oauth-protected-resource/mcp", scope="issues:read issues:write"),
             ~s(DPoP resource_metadata="http://www.example.com/.well-known/oauth-protected-resource/mcp", scope="issues:read issues:write", algs="RS256 PS256 ES256 ES384")
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

  test "the canonical resource follows the mounted path, on the issuer's origin", %{
    config: config
  } do
    alias Sake.Auth.{External, Resource}

    conn =
      conn(:post, "/acme/mcp")
      |> Map.put(:scheme, :https)
      |> Map.put(:host, "App.Example")
      |> Map.put(:port, 443)

    # Sake's own server: the issuer's origin, whatever the request's host.
    assert Resource.canonical(conn, config, %{}) == "http://www.example.com/acme/mcp"

    # An external one: its `url:`, else the request's own origin.
    assert Resource.canonical(conn, %External{url: "https://mcp.example"}, %{}) ==
             "https://mcp.example/acme/mcp"

    assert Resource.canonical(conn, %External{}, %{}) == "https://app.example/acme/mcp"
    conn = conn(:post, "/mcp/") |> Map.put(:port, 8443) |> Map.put(:scheme, :https)
    assert Resource.canonical(conn, %External{}, %{}) == "https://www.example.com:8443/mcp"

    assert Resource.canonical(conn, config, %{resource: fn _ -> "https://fixed.example/mcp" end}) ==
             "https://fixed.example/mcp"

    assert Resource.url_origin("HTTPS://Issuer.Example:443/realm/") == "https://issuer.example"
    assert Resource.url_origin("http://localhost:4000") == "http://localhost:4000"

    assert Resource.metadata_url("http://www.example.com/acme/mcp") ==
             "http://www.example.com/.well-known/oauth-protected-resource/acme/mcp"
  end

  test "a middleware's forbidden halt: scopes to step up to are a challenge; none, none" do
    for {scopes, challenge} <- [{["admin"], [~s(scope="admin")]}, {[], []}] do
      conn =
        conn(:post, "/mcp")
        |> assign(:sake_auth, true)
        |> Sake.Plug.outcome_to_response(1, {:forbidden, scopes})

      assert conn.status == 403

      assert Enum.map(get_resp_header(conn, "www-authenticate"), fn header ->
               header |> String.split(", ") |> Enum.at(1)
             end) == challenge
    end
  end

  test "behind a proxy, a token for the issuer's origin is accepted and challenges name it", %{
    config: config
  } do
    {access, _, _} =
      issue(config, %{scopes: ["issues:read"], resource: "http://www.example.com/mcp"})

    # The proxy reaches the app at its upstream's address.
    proxied = [host: "app.internal"]

    conn =
      ModernClient.post(
        opts(),
        "tools/list",
        %{},
        [headers: [{"authorization", "Bearer " <> access}]] ++ proxied
      )

    assert conn.status == 200

    conn = ModernClient.post(opts(), "tools/list", %{}, proxied)
    assert conn.status == 401
    assert [_bearer, _dpop] = challenges = get_resp_header(conn, "www-authenticate")

    for challenge <- challenges,
        do:
          assert(
            challenge =~
              ~s(resource_metadata="http://www.example.com/.well-known/oauth-protected-resource/mcp")
          )
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
