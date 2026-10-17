defmodule Sake.Client.AuthStepUpE2ETest.DeleteRepo do
  @moduledoc false
  use Sake.Tool,
    name: "delete_repo",
    description: "Delete a repository",
    scope: "issues:read",
    authentication: [acr: ["mfa"], max_age: 300]

  arg :name, :string, required: true

  @impl true
  def execute(%{name: name}, _ctx), do: {:ok, "deleted #{name}"}
end

defmodule Sake.Client.AuthStepUpE2ETest.Server do
  @moduledoc false
  use Sake.Server, name: "step-up", version: "1.0.0"
  scope "issues:read", "Read issues"
  tools [Sake.Client.AuthStepUpE2ETest.DeleteRepo, SakeDev.Tools.Echo]
end

defmodule Sake.Client.AuthStepUpE2ETest.Router do
  @moduledoc false
  # The development router, with an endpoint whose tool needs MFA.
  use Plug.Router
  plug :match
  plug :dispatch

  forward "/stepup/mcp",
    to: Sake.Plug,
    init_opts: [server: Sake.Client.AuthStepUpE2ETest.Server, auth: true]

  match _, do: SakeDev.Router.call(conn, SakeDev.Router.init([]))
end

defmodule Sake.Client.AuthStepUpE2ETest do
  # Sake.Client steps up on `insufficient_user_authentication` (RFC 9470)
  # against Sake's own authorization server: the development router on a
  # real port, whose login records "pwd" for a password and "mfa" with
  # the one-time code, and whose subject module sends a person back to it
  # when a request asks for MFA. The client runs the person's grant again
  # with the challenge's acr_values and max_age, once per request.
  use ExUnit.Case, async: false

  alias Sake.Auth.{Challenge, Clients, Tokens}
  alias Sake.Client
  alias SakeTest.HTTP

  setup tags do
    base = HTTP.start(Sake.Client.AuthStepUpE2ETest.Router)

    start_supervised!(
      {Sake,
       auth: [
         subject: SakeDev.Subject,
         issuer: base,
         allow_insecure: true,
         servers: [SakeDev.Server],
         resources: ["/mcp", "/stepup/mcp"],
         store: {Sake.Auth.Store.ETS, []},
         device: [interval: 1],
         par: Map.get(tags, :par, false),
         acr_values: ["pwd", "mfa"]
       ],
       secret_key_base: SakeTest.ModernClient.secret(),
       streams: false,
       tasks: false}
    )

    {:ok, jar} = Agent.start_link(fn -> nil end)
    %{base: base, url: base <> "/stepup/mcp", jar: jar}
  end

  test "the code flow runs again with acr_values and max_age, and the call goes through", ctx do
    assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])
    assert_received {:authorized, first}
    refute Map.has_key?(first, "acr_values")
    assert_received {:signed_in, "pwd"}
    assert_received :consented
    assert acr(session) == "pwd"

    assert {:ok, %{text: "hi"}, session} = Client.call_tool(session, "echo", %{"text" => "hi"})

    # The tool needs MFA: the client asks again, the authorization server
    # sends Ana back to the login for her one-time code, and the consent
    # she gave before covers the rest.
    assert {:ok, %{text: "deleted x"}, session} =
             Client.call_tool(session, "delete_repo", %{"name" => "x"})

    assert_received {:authorized, %{"acr_values" => "mfa", "max_age" => "300"} = second}
    assert second["scope"] == first["scope"]
    assert_received {:signed_in, "mfa"}
    refute_received :consented
    assert acr(session) == "mfa"

    # The next call needs nobody.
    assert {:ok, %{text: "deleted y"}, _session} =
             Client.call_tool(session, "delete_repo", %{"name" => "y"})

    refute_received {:authorized, _}
  end

  @tag par: true
  test "a pushed request carries them, and is kept while Ana signs in again", ctx do
    assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])
    assert_received {:authorized, %{"request_uri" => _}}
    assert_received {:signed_in, "pwd"}

    assert {:ok, %{text: "deleted x"}, session} =
             Client.call_tool(session, "delete_repo", %{"name" => "x"})

    # The browser carried only the request_uri; the pushed request had
    # the rest, and was there again when she came back with MFA.
    assert_received {:authorized, second}
    assert Map.keys(second) |> Enum.sort() == ["client_id", "request_uri"]
    assert_received {:signed_in, "mfa"}
    assert acr(session) == "mfa"
  end

  test "a sign-in the server still refuses ends the request after one step-up", ctx do
    # Ana's browser drops acr_values and max_age on the way: the token
    # she gets says "pwd" again.
    send(self(), :drop_step_up)
    assert {:ok, session} = Client.connect(ctx.url, auth: [authorize: person(ctx)])
    assert_received {:authorized, _}

    assert {:error,
            {:insufficient_user_authentication,
             %Challenge{acr_values: ["mfa"], max_age: 300, error_description: description}},
            session} = Client.call_tool(session, "delete_repo", %{"name" => "x"})

    assert description == "A different authentication level is required"
    assert_received {:authorized, _}
    refute_received {:authorized, _}
    assert acr(session) == "pwd"
  end

  test "the device flow runs again with acr_values", ctx do
    auth = [grant: :device, device_prompt: device_person(ctx), sleep: fn _ms -> :ok end]
    assert {:ok, session} = Client.connect(ctx.url, auth: auth)
    assert_received {:signed_in, "pwd"}

    assert {:ok, %{text: "deleted x"}, session} =
             Client.call_tool(session, "delete_repo", %{"name" => "x"})

    assert_received {:device_started, "mfa"}
    assert_received {:signed_in, "mfa"}
    assert acr(session) == "mfa"
  end

  test "a machine grant cannot sign anyone in again", ctx do
    {:ok, client, secret} =
      Clients.create(Sake.Auth.config(), %{
        name: "Nightly",
        grant_types: ["client_credentials"],
        confidential: true
      })

    auth = [grant: :client_credentials, client_id: client.id, client_secret: secret]
    assert {:ok, session} = Client.connect(ctx.url, auth: auth)
    assert {:ok, %{text: "hi"}, session} = Client.call_tool(session, "echo", %{"text" => "hi"})

    assert {:error,
            {:auth,
             {:insufficient_user_authentication,
              %Challenge{error: "insufficient_user_authentication", acr_values: ["mfa"]}}},
            _session} = Client.call_tool(session, "delete_repo", %{"name" => "x"})
  end

  # How the person behind the session's token signed in, from Sake's record.
  defp acr(session) do
    {module, state} = Sake.Auth.store(Sake.Auth.config())

    {:ok, record} =
      module.get_token(state, :access, Tokens.hash(session.auth.token["access_token"]))

    record.acr
  end

  # ---- Ana, at a browser

  defp person(ctx) do
    test = self()

    fn url ->
      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      send(test, {:authorized, query})

      url =
        receive do
          :drop_step_up -> drop_step_up(url)
        after
          0 -> url
        end

      visit(ctx, test, url)
    end
  end

  defp drop_step_up(url) do
    send(self(), :drop_step_up)
    uri = URI.parse(url)
    query = uri.query |> URI.decode_query() |> Map.drop(["acr_values", "max_age"])
    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  defp visit(ctx, test, url) do
    resp =
      Req.get!(absolute(ctx.base, url), headers: cookie(ctx.jar), redirect: false, retry: false)

    keep(ctx.jar, resp)

    case {resp.status, location(resp)} do
      {302, "/login?" <> _ = login} -> sign_in(ctx, test, login, &visit(ctx, test, &1))
      {302, location} -> {:ok, query(location)}
      {200, _} -> approve(ctx, test, resp.body)
    end
  end

  # She signs in with her password, and with her one-time code as well
  # when the page asks for it.
  defp sign_in(ctx, test, login, next) do
    asked = query(login)
    otp = if asked["acr"] == "mfa", do: SakeDev.Accounts.otp(), else: ""

    resp =
      Req.post!(ctx.base <> "/login",
        form: [
          email: "ana@example.com",
          password: "secret",
          otp: otp,
          return_to: asked["return_to"]
        ],
        redirect: false,
        retry: false
      )

    send(test, {:signed_in, if(otp == "", do: "pwd", else: "mfa")})
    keep(ctx.jar, resp)
    next.(location(resp))
  end

  defp approve(ctx, test, page) do
    send(test, :consented)

    resp =
      Req.post!(ctx.base <> "/oauth/authorize",
        form: [decision: "approve", request: request(page)],
        headers: cookie(ctx.jar),
        redirect: false,
        retry: false
      )

    {:ok, query(location(resp))}
  end

  # ---- Ana, on another device

  # The device flow shows the code; she opens the verification URL,
  # signs in when asked, submits the code and approves, before the
  # client's first poll.
  defp device_person(ctx) do
    test = self()

    fn info ->
      %{"user_code" => user_code} = query(info.verification_uri_complete)
      grant = device_grant(user_code)
      send(test, {:device_started, (grant.extra["acr_values"] || []) |> Enum.join(" ")})
      device_page(ctx, test, info.verification_uri_complete)
    end
  end

  defp device_page(ctx, test, url) do
    resp =
      Req.get!(absolute(ctx.base, url), headers: cookie(ctx.jar), redirect: false, retry: false)

    keep(ctx.jar, resp)

    case {resp.status, location(resp)} do
      {302, "/login?" <> _ = login} -> sign_in(ctx, test, login, &device_page(ctx, test, &1))
      {200, _} -> enter(ctx, test, resp.body)
    end
  end

  defp enter(ctx, test, page) do
    [_, code] = Regex.run(~r/name="user_code" value="([^"]+)"/, page)
    resp = device_post(ctx, user_code: code, request: request(page))

    case {resp.status, location(resp)} do
      # MFA is asked for: back to the login, then to the page with the code.
      {302, "/login?" <> _ = login} ->
        sign_in(ctx, test, login, &device_page(ctx, test, &1))

      {200, _} ->
        200 = device_post(ctx, decision: "approve", request: request(resp.body)).status
        :ok
    end
  end

  defp device_post(ctx, form),
    do:
      Req.post!(ctx.base <> "/oauth/device",
        form: form,
        headers: cookie(ctx.jar),
        redirect: false,
        retry: false
      )

  defp device_grant(user_code) do
    {:ok, %{grant: grant}} = Sake.Auth.Device.lookup(Sake.Auth.config(), user_code)
    grant
  end

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
