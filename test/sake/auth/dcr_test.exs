defmodule Sake.Auth.DCRTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  defp register(body) do
    conn(:post, "/oauth/register", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Sake.Auth.DCR.call(Sake.Auth.DCR.init([]))
  end

  test "registers a public native client", %{config: config} do
    conn =
      register(%{
        "client_name" => "Claude Code",
        "redirect_uris" => ["http://localhost:53421/callback"],
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none",
        "application_type" => "native"
      })

    assert conn.status == 201
    assert ["no-store"] = get_resp_header(conn, "cache-control")
    body = JSON.decode!(conn.resp_body)
    assert "dc_" <> _ = body["client_id"]
    assert is_integer(body["client_id_issued_at"])
    assert body["client_name"] == "Claude Code"
    assert body["redirect_uris"] == ["http://localhost:53421/callback"]
    assert body["token_endpoint_auth_method"] == "none"
    refute Map.has_key?(body, "client_secret")

    assert {:ok, %{kind: :dynamic, application_type: "native"}} =
             Sake.Auth.Clients.get(config, body["client_id"])
  end

  test "rejects bad metadata" do
    conn = register(%{"client_name" => "x", "redirect_uris" => ["http://evil.example/cb"]})
    assert %{"error" => "invalid_redirect_uri"} = JSON.decode!(conn.resp_body)
    conn = register(%{"client_name" => "x"})
    assert conn.status == 400 and JSON.decode!(conn.resp_body)["error"] == "invalid_redirect_uri"

    conn =
      register(%{
        "client_name" => String.duplicate("x", 101),
        "redirect_uris" => ["https://a.example/cb"]
      })

    assert JSON.decode!(conn.resp_body)["error"] == "invalid_client_metadata"

    conn =
      register(%{
        "client_name" => "x",
        "redirect_uris" => Enum.map(1..11, &"https://a.example/cb#{&1}")
      })

    assert JSON.decode!(conn.resp_body)["error"] == "invalid_client_metadata"

    conn =
      register(%{
        "client_name" => "x",
        "redirect_uris" => ["https://a.example/cb"],
        "token_endpoint_auth_method" => "client_secret_basic"
      })

    assert JSON.decode!(conn.resp_body)["error"] == "invalid_client_metadata"

    conn =
      register(%{
        "client_name" => "x",
        "redirect_uris" => ["https://a.example/cb"],
        "grant_types" => ["implicit"]
      })

    assert JSON.decode!(conn.resp_body)["error"] == "invalid_client_metadata"

    conn =
      conn(:post, "/oauth/register", "{")
      |> put_req_header("content-type", "application/json")
      |> Sake.Auth.DCR.call([])

    assert conn.status == 400
  end

  test "optional metadata must have its type" do
    base = %{"client_name" => "x", "redirect_uris" => ["https://a.example/cb"]}

    for {field, value} <- [
          {"client_uri", 1},
          {"logo_uri", %{}},
          {"application_type", ["native"]},
          {"scope", ["issues:read"]},
          {"grant_types", "authorization_code"},
          {"grant_types", [1]}
        ] do
      conn = register(Map.put(base, field, value))
      assert conn.status == 400, field
      assert JSON.decode!(conn.resp_body)["error"] == "invalid_client_metadata", field
    end
  end

  test "a client that names no grant types may use both, and is told so", %{config: config} do
    conn = register(%{"client_name" => "x", "redirect_uris" => ["https://a.example/cb"]})
    body = JSON.decode!(conn.resp_body)
    assert body["grant_types"] == ["authorization_code", "refresh_token"]

    assert {:ok, %{grant_types: ["authorization_code", "refresh_token"]}} =
             Sake.Auth.Clients.get(config, body["client_id"])
  end

  test "a body already parsed by Plug.Parsers is used as it is" do
    doc = %{"client_name" => "Parsed", "redirect_uris" => ["https://a.example/cb"]}

    conn =
      conn(:post, "/oauth/register", JSON.encode!(doc))
      |> put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: JSON))
      |> Sake.Auth.DCR.call([])

    assert conn.status == 201 and JSON.decode!(conn.resp_body)["client_name"] == "Parsed"
  end

  @tag auth: [dcr: false]
  test "off" do
    assert register(%{"client_name" => "x", "redirect_uris" => ["https://a.example/cb"]}).status ==
             404
  end

  # Plug.Test does not check that a plug answers on the conn its last
  # Plug.Conn call returned; Bandit refuses a stale one.
  test "a refusal after the body is read goes out on a real server, and the connection lives on" do
    Application.ensure_all_started(:req)
    url = SakeTest.HTTP.start(Sake.Auth.DCR) <> "/oauth/register"
    req = [retry: false, headers: [{"content-type", "application/json"}]]

    assert %{status: 400, body: %{"error" => "invalid_client_metadata"}} =
             Req.post!(url, [body: "[]"] ++ req)

    assert %{status: 400, body: %{"error" => "invalid_client_metadata"}} =
             Req.post!(url, [body: "{"] ++ req)

    assert %{status: 201} =
             Req.post!(
               url,
               [
                 json: %{
                   "client_name" => "Claude Code",
                   "redirect_uris" => ["http://localhost:53421/callback"]
                 }
               ] ++ req
             )
  end
end
