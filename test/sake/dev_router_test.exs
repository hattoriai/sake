defmodule Sake.DevRouterTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  @tag auth: [issuer: "http://www.example.com", resources: ["/mcp", "/acme/mcp", "/beta/mcp"]]
  test "return_to only ever redirects within this app" do
    router = &SakeDev.Router.call(&1, SakeDev.Router.init([]))

    login = fn return_to ->
      conn(:post, "/login", %{
        "email" => "ana@example.com",
        "password" => "secret",
        "return_to" => return_to
      })
      |> router.()
    end

    conn = login.("https://evil.example")
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/"]

    conn = login.("//evil.example/x")
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/"]

    conn = login.("/oauth/authorize?client_id=x")
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/oauth/authorize?client_id=x"]
  end
end
