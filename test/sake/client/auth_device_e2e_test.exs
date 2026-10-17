defmodule Sake.Client.AuthDeviceE2ETest do
  # Sake.Client with `grant: :device` against Sake's own authorization
  # server: the development router on a real port, its login form, the
  # verification page and the consent page, with a "person" who opens the
  # verification URL on another device, signs in and decides. The client
  # waits through the test's `:sleep`, which never really sleeps: the
  # interval is one second, and the person's last step moves the grant's
  # last poll back by it instead.
  use ExUnit.Case, async: false

  alias Sake.Client
  alias SakeTest.HTTP

  @device_code "urn:ietf:params:oauth:grant-type:device_code"

  defmodule Recorder do
    @moduledoc false
    # The development router, telling the test the error of every answer
    # of the token endpoint.
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      conn
      |> register_before_send(fn conn ->
        if conn.request_path == "/oauth/token" do
          error = conn.resp_body |> IO.iodata_to_binary() |> JSON.decode!() |> Map.get("error")
          send(test, {:token, conn.status, error})
        end

        conn
      end)
      |> SakeDev.Router.call(SakeDev.Router.init([]))
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
         device: Map.get(tags, :device, interval: 1)
       ],
       secret_key_base: SakeTest.ModernClient.secret(),
       streams: false,
       tasks: false}
    )

    {:ok, jar} = Agent.start_link(fn -> nil end)
    %{base: base, url: base <> "/acme/mcp", jar: jar}
  end

  test "pending, slow_down, approve, then a tool call; a dead token runs it again", ctx do
    auth = [grant: :device, device_prompt: prompt(), sleep: sleep(ctx, "approve")]
    assert {:ok, session} = Client.connect(ctx.url, auth: auth)

    assert_received {:prompt, %{user_code: user_code, verification_uri: uri} = shown}
    assert uri == ctx.base <> "/oauth/device"
    assert shown.verification_uri_complete =~ "user_code="
    assert shown.expires_in == 600
    assert user_code =~ ~r/\A[A-Z]{4}-[A-Z]{4}\z/

    # The first poll waited the interval and found the person undecided;
    # the second came at once and was told to slow down, so the third
    # waited five seconds more, by when the person had approved.
    assert_received {:slept, 1_000}
    assert_received {:token, 400, "authorization_pending"}
    assert_received {:slept, 1_000}
    assert_received {:token, 400, "slow_down"}
    assert_received {:slept, 6_000}
    assert_received :consented
    assert_received {:token, 200, nil}

    token = session.auth.token
    assert token["token_type"] == "DPoP"
    assert token["refresh_token"]
    assert token["scopes"] == ["issues:read", "issues:write"]

    # The client registered for the device grant, with no redirect URI.
    {module, state} = Sake.Auth.store(Sake.Auth.config())
    {:ok, client} = module.get_client(state, token["client_id"])
    assert client.grant_types == [@device_code, "refresh_token"]
    assert client.redirect_uris == []

    assert {:ok, %{text: "hi"}, session} = Client.call_tool(session, "echo", %{"text" => "hi"})

    # An expiring token is refreshed, with no one asked again.
    session = put_in(session.auth.token["expires_at"], System.system_time(:second))
    assert {:ok, _result, session} = Client.call_tool(session, "echo", %{"text" => "x"})
    refute_received {:prompt, _}

    # A token the server refuses, with no refresh token left: the device
    # flow runs again.
    session =
      put_in(session.auth.token, %{
        session.auth.token
        | "access_token" => "revoked",
          "refresh_token" => nil
      })

    assert {:ok, %{text: "again"}, _session} =
             Client.call_tool(session, "echo", %{"text" => "again"})

    assert_received {:prompt, %{user_code: second}}
    assert second != user_code
  end

  test "a denial ends the flow", ctx do
    auth = [grant: :device, device_prompt: prompt(), sleep: sleep(ctx, "deny")]

    assert {:error, {:auth, :access_denied}} = Client.connect(ctx.url, auth: auth)
    assert_received {:token, 400, "access_denied"}
  end

  test "an expired device code ends the flow", ctx do
    # During the first wait the code expires, as if the person never came.
    expire = fn _ms ->
      table = Sake.Auth.Store.ETS.DeviceGrants
      [{hash, grant, fence}] = :ets.tab2list(table)
      past = DateTime.add(DateTime.utc_now(), -1)
      :ets.insert(table, {hash, %{grant | expires_at: past}, fence})
    end

    auth = [grant: :device, device_prompt: prompt(), sleep: expire]
    assert {:error, {:auth, :expired_token}} = Client.connect(ctx.url, auth: auth)
    assert_received {:token, 400, "expired_token"}
  end

  @tag device: false
  test "a server without the device endpoint", ctx do
    auth = [grant: :device, device_prompt: prompt()]
    assert {:error, {:auth, :no_device_endpoint}} = Client.connect(ctx.url, auth: auth)
    refute_received {:prompt, _}
  end

  # Shows the code by telling the test, and keeps it for the person.
  defp prompt do
    test = self()

    fn info ->
      Process.put(:shown, info)
      send(test, {:prompt, info})
    end
  end

  # The client's waits, three for each flow: the first two pass at once
  # (a pending poll, then one too soon); during the third the person
  # signs in on another device and decides, and the grant's last poll is moved back past the
  # interval, as the real wait would have done.
  defp sleep(%{base: base, jar: jar}, decision) do
    test = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    fn ms ->
      send(test, {:slept, ms})

      if rem(Agent.get_and_update(calls, &{&1 + 1, &1 + 1}), 3) == 0 do
        # The flow runs in the process that connects: the code it showed
        # is in its dictionary.
        info = Process.get(:shown)
        visit(base, jar, test, info.verification_uri_complete, decision)
        waited(info)
      end

      :ok
    end
  end

  defp waited(%{user_code: user_code}) do
    config = Sake.Auth.config()
    {:ok, code} = Sake.Auth.Device.normalize(user_code)
    hash = Sake.Auth.Device.user_code_hash(config, code)
    table = Sake.Auth.Store.ETS.DeviceGrants
    [{key, grant, fence}] = :ets.match_object(table, {:_, %{user_code_hash: hash}, :_})
    last = DateTime.add(grant.last_polled_at, -grant.interval, :second)
    :ets.insert(table, {key, %{grant | last_polled_at: last}, fence})
  end

  # Ana, on her phone: opens the verification URL, signs in when asked,
  # confirms the prefilled code, and decides on the consent page.
  defp visit(base, jar, test, url, decision) do
    resp = Req.get!(absolute(base, url), headers: cookie(jar), redirect: false, retry: false)
    keep(jar, resp)

    case {resp.status, location(resp)} do
      {302, "/login?" <> _ = login} -> sign_in(base, jar, test, login, decision)
      {200, _} -> enter(base, jar, test, resp.body, decision)
    end
  end

  defp sign_in(base, jar, test, login, decision) do
    resp =
      Req.post!(base <> "/login",
        form: [email: "ana@example.com", password: "secret", return_to: query(login)["return_to"]],
        redirect: false,
        retry: false
      )

    keep(jar, resp)
    visit(base, jar, test, location(resp), decision)
  end

  defp enter(base, jar, test, page, decision) do
    [_, code] = Regex.run(~r/name="user_code" value="([^"]+)"/, page)
    resp = post(base, jar, user_code: code, request: request(page))
    200 = resp.status
    send(test, :consented)
    resp = post(base, jar, decision: decision, request: request(resp.body))
    200 = resp.status
  end

  defp post(base, jar, form),
    do:
      Req.post!(base <> "/oauth/device",
        form: form,
        headers: cookie(jar),
        redirect: false,
        retry: false
      )

  defp request(page) do
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, page)
    request
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
