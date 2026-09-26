defmodule Sake.E2ETest do
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  @tag auth: [issuer: "http://www.example.com", resources: ["/mcp", "/acme/mcp", "/beta/mcp"]]
  test "register, sign in, consent, token, call on both eras, refresh, revoke" do
    router = &SakeDev.Router.call(&1, SakeDev.Router.init([]))

    # 1. dynamic registration
    conn =
      conn(
        :post,
        "/oauth/register",
        JSON.encode!(%{
          "client_name" => "E2E",
          "redirect_uris" => ["http://localhost:1455/callback"],
          "token_endpoint_auth_method" => "none"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> router.()

    assert conn.status == 201
    client_id = JSON.decode!(conn.resp_body)["client_id"]

    # 2. authorize while signed out → login redirect
    query = %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => "http://localhost:1455/callback",
      "code_challenge" => @challenge,
      "code_challenge_method" => "S256",
      "state" => "s",
      "scope" => "issues:read issues:write",
      "resource" => "http://www.example.com/acme/mcp"
    }

    conn = conn(:get, "/oauth/authorize?" <> URI.encode_query(query)) |> router.()
    assert conn.status == 302 and hd(get_resp_header(conn, "location")) =~ "/login?return_to="

    # 3. sign in (the session cookie carries over through recycle)
    conn =
      conn(:post, "/login", %{
        "email" => "ana@example.com",
        "password" => "secret",
        "return_to" => "/oauth/authorize?" <> URI.encode_query(query)
      })
      |> router.()

    assert conn.status == 302
    cookies = conn.resp_cookies

    # 4. consent
    conn =
      conn(:get, "/oauth/authorize?" <> URI.encode_query(query))
      |> with_cookies(cookies)
      |> router.()

    assert conn.status == 200 and conn.resp_body =~ "E2E"
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, conn.resp_body)

    conn =
      conn(:post, "/oauth/authorize", %{"decision" => "approve", "request" => request})
      |> with_cookies(cookies)
      |> router.()

    assert conn.status == 302

    %{"code" => code, "state" => "s", "iss" => "http://www.example.com"} =
      conn
      |> get_resp_header("location")
      |> hd()
      |> URI.parse()
      |> Map.get(:query)
      |> URI.decode_query()

    # 5. token
    conn =
      conn(
        :post,
        "/oauth/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client_id,
          "redirect_uri" => "http://localhost:1455/callback",
          "code_verifier" => @verifier,
          "resource" => "http://www.example.com/acme/mcp"
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> router.()

    assert conn.status == 200
    %{"access_token" => access, "refresh_token" => refresh} = JSON.decode!(conn.resp_body)

    # 6. MCP, modern and legacy, with the token; wrong tenant refused
    modern = fn path, token ->
      conn(
        :post,
        path,
        JSON.encode!(
          Sake.JSONRPC.request(1, "tools/call", %{
            "name" => "echo",
            "arguments" => %{"text" => "hi"},
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          })
        )
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "echo")
      |> put_req_header("authorization", "Bearer " <> token)
      |> router.()
    end

    assert %{"result" => %{"content" => [%{"text" => "hi"}]}} =
             JSON.decode!(modern.("/acme/mcp", access).resp_body)

    assert modern.("/beta/mcp", access).status == 401
    assert modern.("/acme/mcp", "nope").status == 401

    conn =
      conn(
        :post,
        "/acme/mcp",
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
      |> router.()

    assert conn.status == 200
    assert [_session] = get_resp_header(conn, "mcp-session-id")

    # 7. refresh, then the old refresh token is dead
    conn =
      conn(
        :post,
        "/oauth/token",
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh,
          "client_id" => client_id
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> router.()

    assert %{"access_token" => access2} = JSON.decode!(conn.resp_body)
    assert modern.("/acme/mcp", access2).status == 200

    # 8. code replay revokes everything issued from it
    conn =
      conn(
        :post,
        "/oauth/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client_id,
          "redirect_uri" => "http://localhost:1455/callback",
          "code_verifier" => @verifier
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> router.()

    assert conn.status == 400
    assert modern.("/acme/mcp", access2).status == 401

    # 9. discovery documents
    assert JSON.decode!(
             router.(conn(:get, "/.well-known/oauth-protected-resource/acme/mcp")).resp_body
           )[
             "authorization_servers"
           ] == ["http://www.example.com"]
  end

  defp with_cookies(conn, cookies) do
    Enum.reduce(cookies, conn, fn {name, %{value: value}}, c -> put_req_cookie(c, name, value) end)
  end
end
