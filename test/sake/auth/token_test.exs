defmodule Sake.Auth.TokenTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.{Authorize, Tokens}

  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  defp request(client, extra \\ %{}),
    do:
      Map.merge(
        %{
          client_id: client.id,
          redirect_uri: hd(client.redirect_uris),
          code_challenge: @challenge,
          scopes: ["issues:read"],
          resource: "http://www.example.com/mcp"
        },
        extra
      )

  defp post(params, headers \\ []) do
    conn =
      conn(:post, "/oauth/token", URI.encode_query(params))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Sake.Auth.Token.call(conn, Sake.Auth.Token.init([]))
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  test "the code grant issues a pair; the code is single use and reuse revokes the family", %{
    config: config
  } do
    client = public_client(config)
    code = Authorize.issue_code(config, request(client), "u1")

    conn =
      post(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => @verifier,
        "resource" => "http://www.example.com/mcp"
      })

    assert conn.status == 200
    assert ["no-store"] = get_resp_header(conn, "cache-control")

    assert %{
             "access_token" => access,
             "refresh_token" => refresh,
             "token_type" => "Bearer",
             "expires_in" => 3600,
             "scope" => "issues:read"
           } = body(conn)

    {mod, state} = Sake.Auth.store(config)

    assert {:ok, %{family_id: family, subject_id: "u1"}} =
             mod.get_token(state, :access, Tokens.hash(access))

    assert family == Tokens.hash(code)

    conn =
      post(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => @verifier
      })

    assert conn.status == 400 and body(conn)["error"] == "invalid_grant"
    assert {:ok, %{revoked_at: %DateTime{}}} = mod.get_token(state, :access, Tokens.hash(access))

    assert {:ok, %{revoked_at: %DateTime{}}} =
             mod.get_token(state, :refresh, Tokens.hash(refresh))
  end

  test "the code grant checks the client, redirect, verifier and resource", %{config: config} do
    client = public_client(config)
    other = public_client(config, %{name: "Other"})

    base = fn ->
      %{
        "grant_type" => "authorization_code",
        "code" => Authorize.issue_code(config, request(client), "u1"),
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => @verifier
      }
    end

    assert body(post(Map.put(base.(), "client_id", other.id)))["error"] == "invalid_grant"

    assert body(post(Map.put(base.(), "redirect_uri", "http://127.0.0.1:9000/other")))["error"] ==
             "invalid_grant"

    assert body(post(Map.put(base.(), "code_verifier", String.duplicate("a", 43))))["error"] ==
             "invalid_grant"

    assert body(post(Map.put(base.(), "resource", "http://www.example.com/beta/mcp")))["error"] ==
             "invalid_grant"

    assert body(post(Map.delete(base.(), "code_verifier")))["error"] == "invalid_request"
    assert body(post(%{"grant_type" => "password"}))["error"] == "unsupported_grant_type"
    assert body(post(Map.put(base.(), "client_id", "nope")))["error"] == "invalid_client"
    assert post(base.()).status == 200
  end

  test "confidential clients authenticate with basic or post secrets", %{config: config} do
    {:ok, client, secret} =
      Sake.Auth.Clients.create(config, %{
        name: "Web",
        redirect_uris: ["https://app.example/cb"],
        confidential: true
      })

    code = Authorize.issue_code(config, request(client), "u1")

    params = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "client_id" => client.id,
      "redirect_uri" => "https://app.example/cb",
      "code_verifier" => @verifier
    }

    conn = post(params)
    assert conn.status == 401 and body(conn)["error"] == "invalid_client"
    assert [~s(Basic realm="sake")] = get_resp_header(conn, "www-authenticate")
    conn = post(params, [{"authorization", "Basic " <> Base.encode64(client.id <> ":wrong")}])
    assert conn.status == 401

    conn =
      post(params, [{"authorization", "Basic " <> Base.encode64(client.id <> ":" <> secret)}])

    assert conn.status == 200
    code = Authorize.issue_code(config, request(client), "u1")
    conn = post(%{params | "code" => code} |> Map.put("client_secret", secret))
    assert conn.status == 200
  end

  test "refresh rotates, narrows scopes, and detects reuse", %{config: config} do
    client = public_client(config)

    code =
      Authorize.issue_code(
        config,
        request(client, %{scopes: ["issues:read", "issues:write"]}),
        "u1"
      )

    %{"refresh_token" => r1, "access_token" => a1} =
      body(
        post(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => hd(client.redirect_uris),
          "code_verifier" => @verifier
        })
      )

    conn =
      post(%{
        "grant_type" => "refresh_token",
        "refresh_token" => r1,
        "client_id" => client.id,
        "scope" => "issues:read"
      })

    assert conn.status == 200
    assert %{"refresh_token" => r2, "access_token" => a2, "scope" => "issues:read"} = body(conn)
    assert r2 != r1 and a2 != a1
    {mod, state} = Sake.Auth.store(config)
    assert {:ok, %{used_at: %DateTime{}}} = mod.get_token(state, :refresh, Tokens.hash(r1))

    assert body(
             post(%{
               "grant_type" => "refresh_token",
               "refresh_token" => r2,
               "client_id" => client.id,
               "scope" => "issues:write"
             })
           )["error"] == "invalid_scope"

    assert body(
             post(%{
               "grant_type" => "refresh_token",
               "refresh_token" => r2,
               "client_id" => public_client(config, %{name: "x"}).id
             })
           )["error"] == "invalid_grant"

    conn =
      post(%{"grant_type" => "refresh_token", "refresh_token" => r1, "client_id" => client.id})

    assert body(conn)["error"] == "invalid_grant"
    assert {:ok, %{revoked_at: %DateTime{}}} = mod.get_token(state, :access, Tokens.hash(a2))
    assert {:ok, %{revoked_at: %DateTime{}}} = mod.get_token(state, :refresh, Tokens.hash(r2))
  end
end
