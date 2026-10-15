defmodule Sake.Client.AuthE2ETest do
  # Sake.Client authorizes against Sake's own authorization server: the
  # development router on a real port, its login form and consent page,
  # with a "person" who signs in and approves in place of a browser.
  use ExUnit.Case, async: false

  alias Sake.Client
  alias SakeTest.HTTP

  defmodule MemoryStore do
    @moduledoc false
    @behaviour Sake.Client.Auth.Store

    @impl true
    def fetch(agent, key), do: Agent.get(agent, &Map.fetch(&1, key))

    @impl true
    def put(agent, key, value), do: Agent.update(agent, &Map.put(&1, key, value))
  end

  setup do
    base = HTTP.start(SakeDev.Router)

    start_supervised!(
      {Sake,
       auth: [
         subject: SakeDev.Subject,
         issuer: base,
         allow_insecure: true,
         servers: [SakeDev.Server],
         resources: ["/mcp", "/acme/mcp", "/beta/mcp"],
         store: {Sake.Auth.Store.ETS, []}
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
