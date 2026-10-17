defmodule Sake.Client.AuthPARE2ETest do
  # Sake.Client pushes its authorization request (RFC 9126) to Sake's own
  # authorization server: the development router on a real port, its
  # login form and consent page, with a "person" who signs in and
  # approves in place of a browser.
  use ExUnit.Case, async: false

  alias Sake.Auth.Tokens
  alias Sake.Client
  alias SakeTest.HTTP

  defmodule Recorder do
    @moduledoc false
    # The development router, telling the test the status and error of
    # every answer of the pushed authorization request endpoint.
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      conn
      |> register_before_send(fn conn ->
        if conn.request_path == "/oauth/par",
          do: send(test, {:par, conn.status, error(conn), get_req_header(conn, "dpop") != []})

        conn
      end)
      |> SakeDev.Router.call(SakeDev.Router.init([]))
    end

    defp error(conn) do
      case IO.iodata_to_binary(conn.resp_body) do
        "" -> nil
        body -> body |> JSON.decode!() |> Map.get("error")
      end
    end
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
         dpop: Map.get(tags, :dpop, true),
         par: Map.get(tags, :par, true)
       ],
       secret_key_base: SakeTest.ModernClient.secret(),
       streams: false,
       tasks: false}
    )

    {:ok, jar} = Agent.start_link(fn -> nil end)
    %{base: base, url: base <> "/acme/mcp", jar: jar}
  end

  test "the request is pushed, the browser carries only its request_uri", ctx do
    assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])

    assert_received {:par, 201, nil, true}
    assert_received {:authorized, query}
    assert %{"client_id" => "dc_" <> _, "request_uri" => request_uri} = query
    assert Map.keys(query) |> Enum.sort() == ["client_id", "request_uri"]
    assert "urn:ietf:params:oauth:request_uri:" <> _ = request_uri

    # The push carried a proof: the token is bound to the client's key.
    token = session.auth.token
    assert token["token_type"] == "DPoP"
    assert token["scopes"] == ["issues:read", "issues:write"]

    {module, state} = Sake.Auth.store(Sake.Auth.config())
    {:ok, record} = module.get_token(state, :access, Tokens.hash(token["access_token"]))
    assert is_binary(record.jkt)

    assert {:ok, %{text: "hi"}, _session} = Client.call_tool(session, "echo", %{"text" => "hi"})
  end

  test "par: false sends the request through the browser", ctx do
    assert {:ok, _session} = Client.connect(ctx.url, auth: [authorize: person(ctx), par: false])
    refute_received {:par, _, _, _}
    assert_received {:authorized, %{"response_type" => "code", "code_challenge" => _}}
  end

  @tag par: [required: true]
  test "a server that requires pushed requests gets them even with par: false", ctx do
    assert {:ok, _session} = Client.connect(ctx.url, auth: [authorize: person(ctx), par: false])
    assert_received {:par, 201, nil, true}
    assert_received {:authorized, %{"request_uri" => _}}
  end

  @tag par: false
  test "a server without pushed requests gets the request through the browser", ctx do
    assert {:ok, _session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])
    refute_received {:par, _, _, _}
    assert_received {:authorized, %{"response_type" => "code"}}
  end

  @tag dpop: [nonce: true]
  test "a server that wants a DPoP nonce gets the push again with it", ctx do
    assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])
    assert_received {:par, 400, "use_dpop_nonce", true}
    assert_received {:par, 201, nil, true}
    assert session.auth.token["token_type"] == "DPoP"
  end

  @tag dpop: false
  test "without DPoP the push carries no proof, and the token is a bearer one", ctx do
    assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])
    assert_received {:par, 201, nil, false}
    assert session.auth.token["token_type"] == "Bearer"
  end

  test "a push the server refuses ends the flow", ctx do
    # A client the server does not know.
    auth = [authorize: person(ctx), client_id: "rc_unknown", issuer: ctx.base]

    assert {:error, {:auth, {:par_failed, 401, %{"error" => "invalid_client"}}}} =
             Client.connect(ctx.url, auth: auth)

    refute_received {:authorized, _}
  end

  test "auth: :par takes :auto or false" do
    assert_raise ArgumentError, ~r/:par/, fn ->
      Client.connect("http://127.0.0.1:1/mcp", auth: [par: true])
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
