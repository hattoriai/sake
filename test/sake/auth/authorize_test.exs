defmodule Sake.Auth.AuthorizeTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.Authorize

  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  defp params(client, extra \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_challenge" => @challenge,
        "code_challenge_method" => "S256",
        "state" => "xyz",
        "scope" => "issues:read",
        "resource" => "http://www.example.com/mcp"
      },
      extra
    )
  end

  defp get(params, user \\ "u1") do
    conn(:get, "/oauth/authorize", params)
    |> init_test_session(%{user_id: user})
    |> Authorize.call(Authorize.init([]))
  end

  defp post(params, user \\ "u1") do
    conn(:post, "/oauth/authorize", params)
    |> init_test_session(%{user_id: user})
    |> Authorize.call(Authorize.init([]))
  end

  defp location(conn),
    do:
      conn
      |> get_resp_header("location")
      |> hd()
      |> URI.parse()
      |> then(&{&1.host, URI.decode_query(&1.query || "")})

  test "renders the consent page and approves", %{config: config} do
    client = public_client(config)
    conn = get(params(client))
    assert conn.status == 200
    assert ["text/html" <> _] = get_resp_header(conn, "content-type")
    assert conn.resp_body =~ "Test CLI"
    assert conn.resp_body =~ "Read issues"
    assert conn.resp_body =~ "Ana Lima"
    assert conn.resp_body =~ "127.0.0.1"
    assert conn.resp_body =~ "on your computer"
    assert [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, conn.resp_body)

    conn = post(%{"decision" => "approve", "request" => request})
    assert conn.status == 302
    {"127.0.0.1", query} = location(conn)
    assert %{"code" => code, "state" => "xyz", "iss" => "http://www.example.com"} = query
    {mod, state} = Sake.Auth.store(config)

    assert {:ok,
            %{
              client_id: client_id,
              scopes: ["issues:read"],
              resource: "http://www.example.com/mcp",
              subject_id: "u1",
              code_challenge: @challenge
            }} = mod.consume_code(state, Sake.Auth.Tokens.hash(code))

    assert client_id == client.id
    assert {:ok, %{scopes: ["issues:read"]}} = mod.get_consent(state, "u1", client.id)
  end

  test "a remembered consent skips the page; a wider scope asks again", %{config: config} do
    client = public_client(config)
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, get(params(client)).resp_body)
    post(%{"decision" => "approve", "request" => request})
    assert get(params(client)).status == 302
    assert get(params(client, %{"scope" => "issues:read issues:write"})).status == 200
  end

  test "deny redirects with access_denied", %{config: config} do
    client = public_client(config)
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, get(params(client)).resp_body)
    conn = post(%{"decision" => "deny", "request" => request})

    assert {"127.0.0.1", %{"error" => "access_denied", "state" => "xyz", "iss" => _}} =
             location(conn)
  end

  test "bad client or redirect renders an error page and never redirects", %{config: config} do
    client = public_client(config)
    conn = get(params(client, %{"client_id" => "nope"}))
    assert conn.status == 400 and conn.resp_body =~ "unknown client"
    conn = get(params(client, %{"redirect_uri" => "http://127.0.0.1:9000/other"}))
    assert conn.status == 400 and conn.resp_body =~ "redirect"
    conn = get(params(client, %{"redirect_uri" => "http://127.0.0.1:41000/callback"}))
    assert conn.status == 200
  end

  test "other errors redirect with an error code", %{config: config} do
    client = public_client(config)

    assert {_, %{"error" => "unsupported_response_type"}} =
             location(get(params(client, %{"response_type" => "token"})))

    assert {_, %{"error" => "invalid_request"}} =
             location(get(params(client, %{"code_challenge_method" => "plain"})))

    assert {_, %{"error" => "invalid_request"}} =
             location(get(Map.delete(params(client), "code_challenge")))

    assert {_, %{"error" => "invalid_scope"}} =
             location(get(params(client, %{"scope" => "admin"})))

    assert {_, %{"error" => "invalid_target"}} =
             location(get(params(client, %{"resource" => "https://other.example/mcp"})))

    assert {_, %{"error" => "invalid_target"}} =
             location(get(params(client, %{"resource" => "http://www.example.com/nothing"})))

    assert {_, %{"error" => "invalid_target", "state" => "xyz"}} =
             location(get(Map.delete(params(client), "resource")))

    assert get(params(client, %{"resource" => "http://www.example.com/acme/mcp"})).status == 200
  end

  @tag auth: [resources: ["/mcp"]]
  test "a missing resource is accepted with exactly one fixed pattern", %{config: config} do
    client = public_client(config)
    conn = get(Map.delete(params(client), "resource"))
    assert conn.status == 200
  end

  test "no scope means every scope", %{config: config} do
    client = public_client(config)
    conn = get(Map.delete(params(client), "scope"))
    assert conn.resp_body =~ "Read issues" and conn.resp_body =~ "Change issues"
  end

  test "signed-out people get a 401 page", %{config: config} do
    client = public_client(config)

    conn =
      conn(:get, "/oauth/authorize", params(client))
      |> init_test_session(%{})
      |> Authorize.call([])

    assert conn.status == 401 and conn.resp_body =~ "Sign in"
  end

  test "the POST is bound to the person and to time", %{config: config} do
    client = public_client(config)
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, get(params(client)).resp_body)
    assert post(%{"decision" => "approve", "request" => request}, "u2").status == 400
    assert post(%{"decision" => "approve", "request" => request <> "x"}).status == 400
  end

  test "a CIMD client is fetched and its name shown", %{config: config} do
    bypass = Bypass.open()
    id = "http://localhost:#{bypass.port}/claude.json"

    Bypass.expect(
      bypass,
      "GET",
      "/claude.json",
      &Plug.Conn.resp(
        &1,
        200,
        JSON.encode!(%{
          "client_id" => id,
          "client_name" => "Claude Code",
          "redirect_uris" => ["http://localhost:1455/callback"],
          "client_uri" => "https://claude.ai"
        })
      )
    )

    client = %{id: id, redirect_uris: ["http://localhost:60000/callback"]}
    conn = get(params(client))

    assert conn.status == 200 and conn.resp_body =~ "Claude Code" and
             conn.resp_body =~ "claude.ai"
  end

  test "a custom consent module", %{config: _config} do
    defmodule Plain do
      @behaviour Sake.Auth.Consent
      def render(assigns),
        do:
          "PLAIN #{assigns.client_name} #{Enum.map_join(assigns.scopes, ",", &elem(&1, 0))} #{assigns.request}"

      def render_error(assigns), do: "ERR #{assigns.message}"
    end

    :persistent_term.put({Sake, :auth}, %{Sake.Auth.config() | consent: Plain})
    client = public_client(Sake.Auth.config())
    conn = get(params(client))
    assert conn.resp_body =~ "PLAIN Test CLI issues:read"
    assert get(params(client, %{"client_id" => "nope"})).resp_body =~ "ERR"
  end
end
