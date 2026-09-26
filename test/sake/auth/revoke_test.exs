defmodule Sake.Auth.RevokeTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  defp post(params) do
    conn(:post, "/oauth/revoke", URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Sake.Auth.Revoke.call([])
  end

  test "revoking a refresh token revokes its family; an access token only itself; unknown is fine",
       %{config: config} do
    client = public_client(config)
    {a, r, %{access: at, refresh: rt}} = issue(config, %{client_id: client.id})
    conn = post(%{"token" => r, "client_id" => client.id})
    assert conn.status == 200 and conn.resp_body == ""
    {mod, state} = Sake.Auth.store(config)
    assert {:ok, %{revoked_at: %DateTime{}}} = mod.get_token(state, :access, at.hash)
    assert {:ok, %{revoked_at: %DateTime{}}} = mod.get_token(state, :refresh, rt.hash)

    {a2, _r2, %{access: at2, refresh: rt2}} =
      issue(config, %{client_id: client.id, family_id: "f2"})

    assert post(%{"token" => a2, "client_id" => client.id, "token_type_hint" => "access_token"}).status ==
             200

    assert {:ok, %{revoked_at: %DateTime{}}} = mod.get_token(state, :access, at2.hash)
    assert {:ok, %{revoked_at: nil}} = mod.get_token(state, :refresh, rt2.hash)

    assert post(%{"token" => "unknown", "client_id" => client.id}).status == 200

    assert post(%{"token" => a, "client_id" => public_client(config, %{name: "o"}).id}).status ==
             200

    assert {:ok, %{revoked_at: %DateTime{}}} = mod.get_token(state, :access, at.hash)
  end

  test "revoking a token forgets the consents the person gave that client", %{config: config} do
    client = public_client(config)
    {mod, state} = Sake.Auth.store(config)

    consent = %Sake.Auth.Consent{
      subject_id: "u1",
      client_id: client.id,
      resource: "http://www.example.com/mcp",
      scopes: [],
      inserted_at: DateTime.utc_now()
    }

    :ok = mod.put_consent(state, consent)
    :ok = mod.put_consent(state, %{consent | resource: "http://www.example.com/acme/mcp"})
    :ok = mod.put_consent(state, %{consent | client_id: "other"})
    {_a, r, _} = issue(config, %{client_id: client.id, subject_id: "u1"})

    assert post(%{"token" => r, "client_id" => client.id}).status == 200
    assert :error = mod.get_consent(state, "u1", client.id, "http://www.example.com/mcp")
    assert :error = mod.get_consent(state, "u1", client.id, "http://www.example.com/acme/mcp")
    assert {:ok, _} = mod.get_consent(state, "u1", "other", "http://www.example.com/mcp")
  end

  test "a non-POST request gets the no-store headers on its 405" do
    conn =
      conn(:get, "/oauth/revoke")
      |> Sake.Auth.Revoke.call(Sake.Auth.Revoke.init([]))

    assert conn.status == 405
    assert ["no-store"] = get_resp_header(conn, "cache-control")
    assert ["no-cache"] = get_resp_header(conn, "pragma")
  end
end
