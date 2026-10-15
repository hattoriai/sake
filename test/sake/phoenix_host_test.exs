defmodule Sake.PhoenixHostTest do
  # The whole flow through a Phoenix endpoint as `mix phx.new` generates
  # it, over a real socket: the endpoint's `Plug.Parsers` reads the body
  # before Sake sees the request, and the authorize routes sit behind
  # `protect_from_forgery`.
  use ExUnit.Case, async: false

  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @redirect "http://127.0.0.1:1455/callback"

  setup do
    start_supervised!(SakeTest.PhoenixEndpoint)
    {:ok, {_ip, port}} = SakeTest.PhoenixEndpoint.server_info(:http)
    base = "http://localhost:#{port}"

    start_supervised!(
      {Sake,
       auth: [
         subject: SakeDev.Subject,
         issuer: base,
         allow_insecure: true,
         servers: [SakeDev.Server],
         resources: ["/:org/mcp"]
       ],
       secret_key_base: String.duplicate("s", 64),
       streams: false,
       tasks: false}
    )

    %{base: base, req: Req.new(base_url: base, redirect: false, retry: false, decode_body: false)}
  end

  test "CIMD client, sign-in, consent under CSRF protection, token, both eras, DCR", %{
    base: base,
    req: req
  } do
    # 1. the client identifies itself with a metadata document
    bypass = Bypass.open()
    client_id = "http://localhost:#{bypass.port}/client.json"

    Bypass.stub(bypass, "GET", "/client.json", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!(%{
          "client_id" => client_id,
          "client_name" => "Phoenix Host Client",
          "redirect_uris" => [@redirect]
        })
      )
    end)

    resource = base <> "/acme/mcp"

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => @redirect,
        "code_challenge" => @challenge,
        "code_challenge_method" => "S256",
        "state" => "s",
        "scope" => "issues:read issues:write",
        "resource" => resource
      })

    # 2. signed out: the 401 page
    resp = Req.get!(req, url: "/oauth/authorize?" <> query)
    assert resp.status == 401 and resp.body =~ "Sign in"

    # 3. sign in
    resp = Req.get!(req, url: "/test-login/u1")
    assert resp.status == 204
    cookie = cookie(resp, nil)

    # 4. the consent page carries a real CSRF token
    resp = Req.get!(req, url: "/oauth/authorize?" <> query, headers: [cookie: cookie])
    assert resp.status == 200 and resp.body =~ "Phoenix Host Client"
    assert resp.body =~ "for #{resource}"
    assert Req.Response.get_header(resp, "x-frame-options") == ["DENY"]
    cookie = cookie(resp, cookie)
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, resp.body)
    [_, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]*)"/, resp.body)
    assert csrf != ""

    # 5. the approval passes protect_from_forgery
    resp =
      Req.post!(req,
        url: "/oauth/authorize",
        form: %{"decision" => "approve", "request" => request, "_csrf_token" => csrf},
        headers: [cookie: cookie]
      )

    assert resp.status == 302
    [location] = Req.Response.get_header(resp, "location")

    assert %{"code" => code, "state" => "s"} =
             location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

    # 6. token
    resp =
      Req.post!(req,
        url: "/oauth/token",
        form: %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client_id,
          "redirect_uri" => @redirect,
          "code_verifier" => @verifier,
          "resource" => resource
        }
      )

    assert resp.status == 200
    %{"access_token" => access} = JSON.decode!(resp.body)

    # 7. a modern tools/call: the body arrives already parsed
    resp =
      Req.post!(req,
        url: "/acme/mcp",
        body:
          JSON.encode!(
            Sake.JSONRPC.request(1, "tools/call", %{
              "name" => "echo",
              "arguments" => %{"text" => "hi"},
              "_meta" => %{
                "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities" => %{}
              }
            })
          ),
        headers:
          mcp_headers(access, [
            {"mcp-protocol-version", "2026-07-28"},
            {"mcp-method", "tools/call"},
            {"mcp-name", "echo"}
          ])
      )

    assert resp.status == 200
    assert %{"result" => %{"content" => [%{"text" => "hi"}]}} = JSON.decode!(resp.body)

    # 8. a legacy initialize, then a legacy request on the session
    resp =
      Req.post!(req,
        url: "/acme/mcp",
        body:
          JSON.encode!(
            Sake.JSONRPC.request(0, "initialize", %{
              "protocolVersion" => "2025-06-18",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "legacy", "version" => "0"}
            })
          ),
        headers: mcp_headers(access, [])
      )

    assert resp.status == 200
    assert %{"result" => %{"protocolVersion" => "2025-06-18"}} = JSON.decode!(resp.body)
    [session] = Req.Response.get_header(resp, "mcp-session-id")

    resp =
      Req.post!(req,
        url: "/acme/mcp",
        body: JSON.encode!(Sake.JSONRPC.request(1, "tools/list", %{})),
        headers:
          mcp_headers(access, [
            {"mcp-session-id", session},
            {"mcp-protocol-version", "2025-06-18"}
          ])
      )

    assert resp.status == 200
    assert %{"result" => %{"tools" => [_ | _]}} = JSON.decode!(resp.body)

    # 9. dynamic registration: the body arrives already parsed
    resp =
      Req.post!(req,
        url: "/oauth/register",
        json: %{"client_name" => "DCR over Phoenix", "redirect_uris" => [@redirect]}
      )

    assert resp.status == 201
    assert %{"client_id" => "dc_" <> _} = JSON.decode!(resp.body)

    # 10. last, since the server closes the connection after it: without
    # the CSRF token the endpoint's own protection refuses the form
    resp =
      Req.post!(req,
        url: "/oauth/authorize",
        form: %{"decision" => "approve", "request" => request},
        headers: [cookie: cookie]
      )

    assert resp.status == 403
  end

  defp mcp_headers(access, extra) do
    [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"authorization", "Bearer " <> access}
    ] ++ extra
  end

  # The session cookie: the newest `set-cookie`, or the one already held.
  defp cookie(resp, current) do
    case Req.Response.get_header(resp, "set-cookie") do
      [] -> current
      values -> values |> List.last() |> String.split(";") |> hd()
    end
  end
end
