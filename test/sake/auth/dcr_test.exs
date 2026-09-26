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

  @tag auth: [dcr: false]
  test "off" do
    assert register(%{"client_name" => "x", "redirect_uris" => ["https://a.example/cb"]}).status ==
             404
  end
end
