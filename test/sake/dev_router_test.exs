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

    rejected = [
      "https://evil.example",
      "//evil.example/x",
      "/\\evil.example",
      "/\\/evil.example",
      "/x\\y",
      "/path\r\nSet-Cookie: a=b",
      "/javascript:alert(1)"
    ]

    for return_to <- rejected do
      conn = login.(return_to)
      assert conn.status == 302

      assert get_resp_header(conn, "location") == ["/"],
             "expected #{inspect(return_to)} to fall back to /"
    end

    accepted = "/oauth/authorize?client_id=x&resource=http://localhost:4000/mcp"
    conn = login.(accepted)
    assert conn.status == 302
    assert get_resp_header(conn, "location") == [accepted]
  end
end
