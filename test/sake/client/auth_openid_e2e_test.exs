defmodule Sake.Client.AuthOpenIDE2ETest do
  # Sake.Client with `auth: [openid: true]` against Sake's own
  # authorization server with `openid:`: the development router on a
  # real port, its login form and consent page, with a "person" who
  # signs in and approves in place of a browser.
  use ExUnit.Case, async: false

  alias Sake.Client
  alias Sake.Client.Auth.IDToken
  alias SakeTest.{HTTP, Keys}

  setup tags do
    base = HTTP.start({SakeDev.Router, SakeDev.Router.init([])})

    start_supervised!(
      {Sake,
       auth: [
         subject: SakeDev.Subject,
         issuer: base,
         allow_insecure: true,
         servers: [SakeDev.Server],
         resources: ["/mcp", "/acme/mcp", "/beta/mcp"],
         store: {Sake.Auth.Store.ETS, []},
         openid: Map.get(tags, :openid, true),
         signing_keys:
           if(Map.get(tags, :openid, true), do: [[kid: "k1", pem: Keys.pem(:rsa)]], else: [])
       ],
       secret_key_base: SakeTest.ModernClient.secret(),
       streams: false,
       tasks: false}
    )

    {:ok, jar} = Agent.start_link(fn -> nil end)
    %{base: base, url: base <> "/acme/mcp", jar: jar}
  end

  test "openid: true asks for openid with a nonce, and keeps the verified claims", ctx do
    auth = [authorize: person(ctx), par: false, openid: true]
    assert {:ok, session} = Client.connect(ctx.url, auth: auth)

    assert_received {:authorized, query}
    assert "openid" in String.split(query["scope"])
    assert is_binary(query["nonce"])

    assert {:ok, claims} = Client.Auth.id_token_claims(session)
    assert %{"sub" => "u1", "iss" => iss, "nonce" => nonce} = claims
    assert iss == ctx.base
    assert nonce == query["nonce"]
    assert claims["aud"] == session.auth.token["client_id"]
    assert "openid" in session.auth.token["scopes"]

    # The MCP server takes the token as before.
    assert {:ok, %{text: "hi"}, _session} = Client.call_tool(session, "echo", %{"text" => "hi"})
  end

  test "a refresh brings a new ID token for the same person", ctx do
    assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx), openid: true])
    {:ok, first} = Client.Auth.id_token_claims(session)

    # The access token is about to expire: the next request refreshes it.
    Process.sleep(1_100)
    token = Map.put(session.auth.token, "expires_at", System.system_time(:second))
    session = %{session | auth: %{session.auth | token: token}}
    assert {:ok, _result, session} = Client.call_tool(session, "echo", %{"text" => "hi"})

    {:ok, second} = Client.Auth.id_token_claims(session)
    assert session.auth.token["access_token"] != token["access_token"]
    assert second["sub"] == first["sub"]
    assert second["auth_time"] == first["auth_time"]
    assert second["iat"] > first["iat"]
    refute Map.has_key?(second, "nonce")
  end

  test "without openid: true, the client asks for no openid and keeps no claims", ctx do
    assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx), par: false])
    assert_received {:authorized, query}
    refute "openid" in String.split(query["scope"] || "")
    refute Map.has_key?(query, "nonce")
    assert Client.Auth.id_token_claims(session) == :error
  end

  @tag openid: false
  test "a server without OpenID Connect gets no openid scope, and the flow goes on", ctx do
    auth = [authorize: person(ctx), par: false, openid: true]
    assert {:ok, session} = Client.connect(ctx.url, auth: auth)
    assert_received {:authorized, query}
    refute "openid" in String.split(query["scope"] || "")
    assert Client.Auth.id_token_claims(session) == :error
  end

  test "auth: :openid takes true or false" do
    assert_raise ArgumentError, ~r/:openid/, fn ->
      Client.connect("http://127.0.0.1:1/mcp", auth: [openid: :auto])
    end
  end

  describe "the checks on an ID token" do
    setup do
      {key, jwk} = Keys.key(:ec, "k")
      {base, _agent} = Keys.serve(%{"/jwks" => %{"keys" => [jwk]}})
      %{key: key, jwks_uri: base <> "/jwks"}
    end

    defp body(key, claims, access \\ "access") do
      now = System.system_time(:second)
      digest = :crypto.hash(:sha256, access)

      claims =
        Map.merge(
          %{
            "iss" => "https://as.example",
            "sub" => "u1",
            "aud" => "client",
            "iat" => now,
            "exp" => now + 60,
            "nonce" => "n",
            "at_hash" => digest |> binary_part(0, 16) |> Base.url_encode64(padding: false)
          },
          claims
        )

      %{"access_token" => access, "id_token" => Keys.sign(claims, key, %{"kid" => "k"})}
    end

    defp verify(body, uri, expect \\ %{nonce: "n"}),
      do: IDToken.verify(body, "https://as.example", uri, "client", expect, [])

    test "a good one passes", %{key: key, jwks_uri: uri} do
      assert {:ok, %{"sub" => "u1"}} = verify(body(key, %{}), uri)
    end

    test "each claim is checked", %{key: key, jwks_uri: uri} do
      assert {:error, {:invalid_id_token, :nonce}} = verify(body(key, %{"nonce" => "x"}), uri)
      assert {:error, {:invalid_id_token, :nonce}} = verify(body(key, %{"nonce" => nil}), uri)

      assert {:error, {:invalid_id_token, :invalid_audience}} =
               verify(body(key, %{"aud" => "other"}), uri)

      assert {:error, {:invalid_id_token, :invalid_issuer}} =
               verify(body(key, %{"iss" => "https://evil.example"}), uri)

      assert {:error, {:invalid_id_token, :expired}} =
               verify(body(key, %{"exp" => System.system_time(:second) - 120}), uri)

      assert {:error, {:invalid_id_token, :at_hash}} =
               verify(%{body(key, %{}) | "access_token" => "another"}, uri)

      assert {:error, {:invalid_id_token, :sub}} =
               verify(body(key, %{"nonce" => nil}), uri, %{sub: "u2"})
    end

    test "a key the set does not have, or no set, fails", %{jwks_uri: uri} do
      {other, _jwk} = Keys.key(:ec, "k")
      assert {:error, {:invalid_id_token, :bad_signature}} = verify(body(other, %{}), uri)
      assert {:error, {:invalid_id_token, :no_jwks_uri}} = verify(body(other, %{}), nil)
      assert {:error, {:invalid_id_token, :missing}} = verify(%{}, uri)
    end
  end

  # ---- the person

  defp person(%{base: base, jar: jar}) do
    test = self()

    fn url ->
      send(test, {:authorized, url |> URI.parse() |> Map.get(:query) |> URI.decode_query()})
      visit(base, jar, url)
    end
  end

  defp visit(base, jar, url) do
    resp = Req.get!(absolute(base, url), headers: cookie(jar), redirect: false, retry: false)
    keep(jar, resp)

    case {resp.status, location(resp)} do
      {302, "/login?" <> _ = login} -> sign_in(base, jar, login)
      {302, location} -> {:ok, query(location)}
      {200, _} -> approve(base, jar, resp.body)
    end
  end

  defp sign_in(base, jar, login) do
    resp =
      Req.post!(base <> "/login",
        form: [email: "ana@example.com", password: "secret", return_to: query(login)["return_to"]],
        redirect: false,
        retry: false
      )

    keep(jar, resp)
    visit(base, jar, location(resp))
  end

  defp approve(base, jar, page) do
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, page)

    resp =
      Req.post!(base <> "/oauth/authorize",
        form: [decision: "approve", request: request],
        headers: cookie(jar),
        redirect: false,
        retry: false
      )

    {:ok, query(location(resp))}
  end

  defp absolute(base, "/" <> _ = path), do: base <> path
  defp absolute(_base, url), do: url

  defp location(resp), do: resp |> Req.Response.get_header("location") |> List.first()
  defp query(url), do: url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

  defp cookie(jar) do
    case Agent.get(jar, & &1) do
      nil -> []
      value -> [{"cookie", value}]
    end
  end

  defp keep(jar, resp) do
    case Req.Response.get_header(resp, "set-cookie") do
      [value | _] -> Agent.update(jar, fn _ -> value |> String.split(";") |> hd() end)
      [] -> :ok
    end
  end
end
