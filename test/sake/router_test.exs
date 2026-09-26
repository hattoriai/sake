defmodule Sake.RouterTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test

  defp call(conn) do
    conn
    |> Plug.Session.call(Plug.Session.init(store: :cookie, key: "_t", signing_salt: "x"))
    |> SakeTest.PhoenixRouter.call(SakeTest.PhoenixRouter.init([]))
  end

  test "the macros mount every route" do
    assert call(conn(:get, "/.well-known/oauth-authorization-server")).status == 200
    assert call(conn(:get, "/.well-known/oauth-protected-resource/acme/mcp")).status == 200

    assert call(
             conn(:post, "/oauth/token", "grant_type=x")
             |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
           ).status == 400

    assert call(
             conn(:post, "/oauth/register", "{}")
             |> Plug.Conn.put_req_header("content-type", "application/json")
           ).status == 400

    assert call(
             conn(:post, "/oauth/revoke", "token=x")
             |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
           ).status == 200

    assert call(conn(:get, "/oauth/authorize")).status == 400

    conn =
      call(
        conn(:post, "/acme/mcp")
        |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      )

    assert conn.status == 401
    assert [challenge] = Plug.Conn.get_resp_header(conn, "www-authenticate")
    assert challenge =~ "/.well-known/oauth-protected-resource/acme/mcp"
  end

  test "the Plug router serves the API routes" do
    conn =
      conn(:post, "/token", "grant_type=x")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Sake.Auth.RouterPlug.call(Sake.Auth.RouterPlug.init([]))

    assert conn.status == 400
  end
end
