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
end
