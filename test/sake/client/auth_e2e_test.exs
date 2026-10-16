defmodule Sake.Client.AuthE2ETest do
  # Sake.Client authorizes against Sake's own authorization server: the
  # development router on a real port, its login form and consent page,
  # with a "person" who signs in and approves in place of a browser.
  use ExUnit.Case, async: false

  alias Sake.Auth.{JWT, Tokens}
  alias Sake.Client
  alias SakeTest.HTTP

  defmodule Recorder do
    @moduledoc false
    # The development router, telling the test about every answer: the
    # method and path, the status, the scheme the request's token came
    # with, and whether the answer asked for a DPoP nonce.
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      conn
      |> register_before_send(fn conn ->
        send(
          test,
          {:http, conn.method, conn.request_path, conn.status, scheme(conn), nonce?(conn)}
        )

        conn
      end)
      |> SakeDev.Router.call(SakeDev.Router.init([]))
    end

    defp scheme(conn) do
      case get_req_header(conn, "authorization") do
        [header] -> header |> String.split(" ") |> hd()
        _ -> nil
      end
    end

    defp nonce?(conn) do
      text = Enum.join(get_resp_header(conn, "www-authenticate")) <> body(conn.resp_body)
      String.contains?(text, "use_dpop_nonce")
    end

    defp body(nil), do: ""
    defp body(body), do: IO.iodata_to_binary(body)
  end

  defmodule MemoryStore do
    @moduledoc false
    @behaviour Sake.Client.Auth.Store

    @impl true
    def fetch(agent, key), do: Agent.get(agent, &Map.fetch(&1, key))

    @impl true
    def put(agent, key, value), do: Agent.update(agent, &Map.put(&1, key, value))
  end

  setup tags do
    base = HTTP.start({Recorder, self()})

    start_supervised!(
      {Sake,
       auth: [
         subject: SakeDev.Subject,
         issuer: base,
         allow_insecure: true,
         servers: [SakeDev.Server],
         resources: ["/mcp", "/acme/mcp", "/beta/mcp"],
         store: {Sake.Auth.Store.ETS, []},
         dpop: Map.get(tags, :dpop, true)
       ],
       secret_key_base: SakeTest.ModernClient.secret(),
       streams: false,
       tasks: false}
    )

    {:ok, jar} = Agent.start_link(fn -> nil end)
    %{base: base, url: base <> "/acme/mcp", jar: jar}
  end

  test "register, sign in, consent, token, then calls on both eras", %{url: url} = ctx do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    auth = [authorize: person(ctx), store: {MemoryStore, store}]

    assert {:ok, session} = Client.connect(url, auth: auth)
    assert session.era == :modern
    assert_received {:authorized, %{"scope" => "issues:read issues:write"} = request}
    assert request["resource"] == url
    assert "dc_" <> _ = request["client_id"]

    assert session.auth.token["scopes"] == ["issues:read", "issues:write"]
    assert session.auth.token["refresh_token"]

    assert {:ok, %{text: "hi"}, session} = Client.call_tool(session, "echo", %{"text" => "hi"})

    assert {:ok, %{text: "counted to 2"}, _session} =
             Client.call_tool(session, "slow", %{"n" => 2})

    # A second session for the same endpoint, on the legacy era, uses the
    # stored token: nobody is asked again.
    assert {:ok, session} = Client.connect(url, era: :legacy, auth: auth)
    assert session.era == :legacy

    assert {:ok, %{text: "again"}, session} =
             Client.call_tool(session, "echo", %{"text" => "again"})

    refute_received {:authorized, _}
    assert :ok = Client.close(session)
  end

  test "a person who grants less is asked again when a tool needs more", ctx do
    send(self(), {:grant_only, "issues:read"})
    assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])
    assert_received {:authorized, %{"scope" => "issues:read"}}
    assert session.auth.token["scopes"] == ["issues:read"]

    # `slow` needs issues:write: the 403 names it, and the step-up asks for
    # both scopes; the consent remembered for issues:read alone does not
    # cover that, so the consent page shows again.
    assert {:ok, %{text: "counted to 1"}, session} =
             Client.call_tool(session, "slow", %{"n" => 1})

    assert_received {:authorized, %{"scope" => "issues:read issues:write"}}
    assert_received :consented
    assert session.auth.token["scopes"] == ["issues:read", "issues:write"]
  end

  test "an expired or refused token is refreshed, with no one asked again", ctx do
    assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])
    assert_received {:authorized, _}
    first = session.auth.token

    session = put_in(session.auth.token["expires_at"], System.system_time(:second))
    assert {:ok, _result, session} = Client.call_tool(session, "echo", %{"text" => "x"})
    second = session.auth.token
    assert second["access_token"] != first["access_token"]
    assert second["refresh_token"] != first["refresh_token"]

    session = put_in(session.auth.token["access_token"], "revoked")
    assert {:ok, _result, session} = Client.call_tool(session, "echo", %{"text" => "x"})
    assert session.auth.token["refresh_token"] != second["refresh_token"]
    refute_received {:authorized, _}

    # Sake rotates refresh tokens and revokes the family on reuse: the
    # first one is dead, so the whole flow runs again (with a remembered
    # consent, the person is not shown the page).
    session = put_in(session.auth.token, %{first | "access_token" => "revoked"})
    assert {:ok, _result, _session} = Client.call_tool(session, "echo", %{"text" => "x"})
    assert_received {:authorized, _}
  end

  describe "DPoP" do
    test "tokens are bound to a key the client keeps, on both eras", %{url: url} = ctx do
      {:ok, store} = Agent.start_link(fn -> %{} end)
      auth = [authorize: person(ctx), store: {MemoryStore, store}]

      assert {:ok, session} = Client.connect(url, auth: auth)
      token = session.auth.token
      assert token["token_type"] == "DPoP"
      assert "-----BEGIN PRIVATE KEY-----" <> _ = token["dpop_key"]

      # The key is in the store with the token: a bound token is useless
      # without it.
      assert Agent.get(store, & &1[{:token, url}])["dpop_key"] == token["dpop_key"]
      assert bound_to(token) == thumbprint(token)

      assert {:ok, %{text: "hi"}, _session} = Client.call_tool(session, "echo", %{"text" => "hi"})
      assert_received {:http, "POST", "/oauth/token", 200, _, false}
      assert_received {:http, "POST", "/acme/mcp", 200, "DPoP", false}

      # A second session on the legacy era: its POSTs, its GET stream and
      # its DELETE all carry the token with a proof for their own method.
      assert {:ok, session} = Client.connect(url, era: :legacy, auth: auth)
      assert session.era == :legacy
      assert {:ok, %{text: "x"}, session} = Client.call_tool(session, "echo", %{"text" => "x"})

      listener = Task.async(fn -> Client.listen(session, %{}, fn _, _ -> :ok end) end)
      assert_receive {:http, "GET", "/acme/mcp", 200, "DPoP", false}, 2_000
      Task.shutdown(listener, :brutal_kill)

      assert :ok = Client.close(session)
      assert_received {:http, "DELETE", "/acme/mcp", 405, "DPoP", false}
      refute_received {:http, _, _, 401, "DPoP", _}
    end

    test "a refresh keeps the key, and the bound token never goes as Bearer", ctx do
      assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])
      first = session.auth.token

      session = put_in(session.auth.token["expires_at"], System.system_time(:second))
      assert {:ok, _result, session} = Client.call_tool(session, "echo", %{"text" => "x"})
      second = session.auth.token
      assert second["access_token"] != first["access_token"]
      assert second["dpop_key"] == first["dpop_key"]
      assert bound_to(second) == thumbprint(first)

      # Sent as a bearer token, the bound token is refused; the client
      # refreshes (with a proof, the refresh token is bound too) and goes on.
      session = put_in(session.auth.token["token_type"], "Bearer")
      assert {:ok, _result, session} = Client.call_tool(session, "echo", %{"text" => "x"})
      assert_received {:http, "POST", "/acme/mcp", 401, "Bearer", false}
      assert session.auth.token["token_type"] == "DPoP"
      assert bound_to(session.auth.token) == thumbprint(first)
      assert_received {:authorized, _}
      refute_received {:authorized, _}
    end

    @tag dpop: [nonce: true]
    test "nonces at the authorization server and the MCP server cost a retry each", ctx do
      assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])
      assert session.auth.token["token_type"] == "DPoP"

      assert_received {:http, "POST", "/oauth/token", 400, nil, true}
      assert_received {:http, "POST", "/oauth/token", 200, nil, false}
      assert_received {:http, "POST", "/acme/mcp", 401, "DPoP", true}
      assert_received {:http, "POST", "/acme/mcp", 200, "DPoP", false}

      # A nonce retry is not an authorization: the person was asked once.
      assert_received {:authorized, _}
      refute_received {:authorized, _}

      # From then on the client sends the latest nonce, to the MCP server
      # and (on the same origin here) to the token endpoint.
      session = put_in(session.auth.token["expires_at"], System.system_time(:second))
      assert {:ok, %{text: "y"}, _session} = Client.call_tool(session, "echo", %{"text" => "y"})
      assert_received {:http, "POST", "/oauth/token", 200, nil, false}
      refute_received {:http, _, _, _, _, true}

      # A new session (on the legacy era; with no store, it authorizes
      # again) starts with no nonce, and its DELETE carries a proof too.
      assert {:ok, session} =
               Client.connect(ctx.url, era: :legacy, auth: [authorize: person(ctx)])

      assert {:ok, %{text: "z"}, session} = Client.call_tool(session, "echo", %{"text" => "z"})
      assert :ok = Client.close(session)
      assert_received {:http, "DELETE", "/acme/mcp", 405, "DPoP", false}
    end

    @tag dpop: [required: true]
    test "a server that requires DPoP: bound tokens, and a clear error without DPoP", ctx do
      assert {:error, {:auth, {:dpop_required, :dpop_off}}} =
               Client.connect(ctx.url, auth: [authorize: person(ctx), dpop: false])

      refute_received {:authorized, _}

      assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])
      assert session.auth.token["token_type"] == "DPoP"
      assert {:ok, %{text: "x"}, _session} = Client.call_tool(session, "echo", %{"text" => "x"})
    end

    test "dpop: false gets a bearer token", ctx do
      assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx), dpop: false])
      assert session.auth.token["token_type"] == "Bearer"
      assert session.auth.token["dpop_key"] == nil
      assert bound_to(session.auth.token) == nil
      assert {:ok, _result, _session} = Client.call_tool(session, "echo", %{"text" => "x"})
      assert_received {:http, "POST", "/acme/mcp", 200, "Bearer", false}
    end
  end

  defp bound_to(%{"access_token" => access}) do
    {module, state} = Sake.Auth.store(Sake.Auth.config())
    {:ok, record} = module.get_token(state, :access, Tokens.hash(access))
    record.jkt
  end

  defp thumbprint(%{"dpop_key" => pem}) do
    {:ok, key} = JWT.private_key(pem)
    key |> JWT.public_jwk() |> JWT.thumbprint()
  end

  # Ana, in a browser: signs in when the authorization server asks, and
  # approves the consent page. After a `{:grant_only, scope}` message, she
  # unticks every other scope the next time (the request is narrowed
  # before it reaches the server).
  defp person(%{base: base, jar: jar}) do
    test = self()

    fn url ->
      url =
        receive do
          {:grant_only, scope} -> narrow(url, scope)
        after
          0 -> url
        end

      send(test, {:authorized, url |> URI.parse() |> Map.get(:query) |> URI.decode_query()})
      visit(base, jar, test, url)
    end
  end

  defp narrow(url, scope) do
    uri = URI.parse(url)
    query = uri.query |> URI.decode_query() |> Map.put("scope", scope) |> URI.encode_query()
    URI.to_string(%{uri | query: query})
  end

  defp visit(base, jar, test, url) do
    resp = Req.get!(absolute(base, url), headers: cookie(jar), redirect: false, retry: false)
    keep(jar, resp)

    case {resp.status, location(resp)} do
      {302, "/login?" <> _ = login} -> sign_in(base, jar, test, login)
      {302, location} -> {:ok, query(location)}
      {200, _} -> approve(base, jar, test, resp.body)
    end
  end

  defp sign_in(base, jar, test, login) do
    resp =
      Req.post!(base <> "/login",
        form: [email: "ana@example.com", password: "secret", return_to: query(login)["return_to"]],
        redirect: false,
        retry: false
      )

    keep(jar, resp)
    visit(base, jar, test, location(resp))
  end

  defp approve(base, jar, test, page) do
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, page)
    send(test, :consented)

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
