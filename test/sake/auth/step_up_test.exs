defmodule Sake.Auth.StepUpTest.Delete do
  @moduledoc false
  use Sake.Tool,
    name: "delete_repo",
    description: "Delete a repository",
    scope: "issues:write",
    authentication: [acr: ["mfa"], max_age: 300]

  arg :name, :string, required: true

  @impl true
  def execute(%{name: name}, _ctx), do: {:ok, "deleted #{name}"}
end

defmodule Sake.Auth.StepUpTest.Transfer do
  @moduledoc false
  # A requirement that depends on the arguments: the middleware below.
  use Sake.Tool, name: "transfer", description: "Move money"
  arg :amount, :integer, required: true

  @impl true
  def execute(%{amount: amount}, _ctx), do: {:ok, "moved #{amount}"}
end

defmodule Sake.Auth.StepUpTest.Echo do
  @moduledoc false
  use Sake.Tool, name: "echo", description: "Echo"
  arg :text, :string, required: true

  @impl true
  def execute(%{text: text}, _ctx), do: {:ok, text}
end

defmodule Sake.Auth.StepUpTest.Secret do
  @moduledoc false
  use Sake.Resource,
    uri: "secret://vault",
    name: "vault",
    authentication: [max_age: 600]

  @impl true
  def read(_params, _ctx), do: {:ok, "the vault"}
end

defmodule Sake.Auth.StepUpTest.LargeTransfers do
  @moduledoc false
  @behaviour Sake.Middleware

  @impl true
  def call(%{tool: %{name: "transfer"}, arguments: %{amount: amount}} = payload, _opts)
      when amount > 1_000,
      do: Sake.Middleware.require_authentication(payload, acr: ["mfa"])

  def call(payload, _opts), do: {:cont, payload}
end

defmodule Sake.Auth.StepUpTest.Server do
  @moduledoc false
  use Sake.Server, name: "step-up", version: "1.0.0"

  scope "issues:read", "Read issues"
  scope "issues:write", "Change issues"

  tools [Sake.Auth.StepUpTest.Delete, Sake.Auth.StepUpTest.Transfer, Sake.Auth.StepUpTest.Echo]
  resources [Sake.Auth.StepUpTest.Secret]

  middleware :before_call, [Sake.Auth.StepUpTest.LargeTransfers]
end

defmodule Sake.Auth.StepUpTest.Strict do
  @moduledoc false
  # A server-wide requirement, on its own components and its mounted ones.
  use Sake.Server, name: "strict", version: "1.0.0", authentication: [acr: ["mfa", "hwk"]]

  tools [Sake.Auth.StepUpTest.Echo]
  mount Sake.Auth.StepUpTest.Server, prefix: "inner"
end

defmodule Sake.Auth.StepUpTest.Subject do
  @moduledoc false
  # The development subject, but with no way of telling how anyone
  # signed in, nor of sending them to sign in again: Sake's defaults.
  @behaviour Sake.Auth.Subject
  defdelegate from_conn(conn), to: SakeDev.Subject
  defdelegate id(person), to: SakeDev.Subject
  defdelegate fetch(id), to: SakeDev.Subject
  defdelegate display(person), to: SakeDev.Subject
end

defmodule Sake.Auth.StepUpTest.Tokens do
  @moduledoc false
  # An external provider's callback, whose tokens say how the person
  # signed in: `auth_time` as a DateTime or in seconds.
  @behaviour Sake.Auth.External

  @impl true
  def verify_token("mfa-now", _conn),
    do: {:ok, claims(%{acr: "mfa", auth_time: DateTime.utc_now()})}

  def verify_token("mfa-old", _conn),
    do: {:ok, claims(%{acr: "mfa", auth_time: System.system_time(:second) - 3_600})}

  def verify_token("pwd", _conn),
    do: {:ok, claims(%{acr: "pwd", auth_time: System.system_time(:second)})}

  def verify_token(_token, _conn), do: :error

  defp claims(extra),
    do:
      Map.merge(
        %{sub: "u1", scope: "issues:read issues:write", aud: "http://www.example.com/mcp"},
        extra
      )
end

defmodule Sake.Auth.StepUpTest do
  # Step-up on how the person signed in (RFC 9470), end to end: the
  # authorization server asks the host how the person signed in and sends
  # them to sign in again when a request asks for more, on the authorize
  # endpoint, a pushed request and the device page; the code, the device
  # grant and a refresh carry `acr` and `auth_time` into the tokens; and
  # the resource refuses a token that does not meet a component's
  # requirement with the RFC 9470 challenge.
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.{Authorize, DeviceVerification, RouterPlug, Tokens}
  alias Sake.Auth.StepUpTest.{Server, Strict}
  alias SakeTest.ModernClient

  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @resource "http://www.example.com/mcp"
  @metadata "http://www.example.com/.well-known/oauth-protected-resource/mcp"
  @device_code "urn:ietf:params:oauth:grant-type:device_code"

  defp params(client, extra) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_challenge" => @challenge,
        "code_challenge_method" => "S256",
        "state" => "xyz",
        "scope" => "issues:read",
        "resource" => @resource
      },
      extra
    )
  end

  # A session signed in as `user`, `acr` and `seconds` ago, as the
  # development login records it.
  defp session(conn, user, acr, seconds) do
    init_test_session(conn, %{
      user_id: user,
      acr: acr,
      auth_time: acr && System.system_time(:second) - seconds
    })
  end

  defp authorize(query, acr \\ nil, seconds \\ 0) do
    conn(:get, "/oauth/authorize", query)
    |> session("u1", acr, seconds)
    |> Authorize.call(Authorize.init([]))
  end

  defp approve(conn, acr, seconds \\ 0) do
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, conn.resp_body)

    conn(:post, "/oauth/authorize", %{"decision" => "approve", "request" => request})
    |> session("u1", acr, seconds)
    |> Authorize.call(Authorize.init([]))
  end

  defp code(%{status: 302} = conn) do
    [location] = get_resp_header(conn, "location")
    %{"code" => code} = URI.decode_query(URI.parse(location).query)
    code
  end

  defp form(path, params) do
    conn(:post, path, URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> RouterPlug.call(RouterPlug.init([]))
  end

  defp exchange(client, code) do
    conn =
      form("/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => @verifier
      })

    assert conn.status == 200, conn.resp_body
    JSON.decode!(conn.resp_body)
  end

  defp record(config, kind, token) do
    {module, state} = Sake.Auth.store(config)
    {:ok, record} = module.get_token(state, kind, Tokens.hash(token))
    record
  end

  defp returned_to(conn) do
    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert "/login?" <> query = location
    URI.decode_query(query)
  end

  describe "the authorize endpoint" do
    test "asks the person to sign in again when the acr is not one asked for", %{config: config} do
      client = public_client(config)
      query = params(client, %{"acr_values" => "mfa", "max_age" => "300"})

      # Signed in with a password: back to the login, asking for MFA, and
      # then to this very request.
      conn = authorize(query, "pwd")
      assert %{"acr" => "mfa", "return_to" => return_to} = returned_to(conn)
      assert return_to == "/oauth/authorize?" <> conn.query_string
      assert URI.decode_query(URI.parse(return_to).query) == query

      # Signed in with MFA: the consent page, and a code that says so.
      conn = authorize(query, "mfa", 10)
      assert conn.status == 200
      code = conn |> approve("mfa", 10) |> code()

      {module, state} = Sake.Auth.store(config)

      assert {:ok, %{acr: "mfa", auth_time: %DateTime{} = at}} =
               module.consume_code(state, Tokens.hash(code))

      assert_in_delta DateTime.to_unix(at), System.system_time(:second) - 10, 2
    end

    test "asks again when the sign-in is older than max_age", %{config: config} do
      client = public_client(config)
      query = params(client, %{"max_age" => "300"})

      assert %{"return_to" => _} = query |> authorize("pwd", 301) |> returned_to()
      refute Map.has_key?(query |> authorize("pwd", 301) |> returned_to(), "acr")
      assert authorize(query, "pwd", 30).status == 200

      # max_age=0: a sign-in within the last minute.
      zero = params(client, %{"max_age" => "0"})
      assert %{} = zero |> authorize("pwd", 120) |> returned_to()
      assert authorize(zero, "pwd", 5).status == 200
    end

    test "a request that asks for nothing is decided as before, whatever the sign-in", %{
      config: config
    } do
      client = public_client(config)
      conn = authorize(params(client, %{}))
      assert conn.status == 200
      code = conn |> approve(nil) |> code()

      {module, state} = Sake.Auth.store(config)
      assert {:ok, %{acr: nil, auth_time: nil}} = module.consume_code(state, Tokens.hash(code))
    end

    test "a bad max_age goes back to the client", %{config: config} do
      client = public_client(config)
      conn = authorize(params(client, %{"max_age" => "soon"}), "mfa")
      assert conn.status == 302
      [location] = get_resp_header(conn, "location")

      assert %{"error" => "invalid_request", "state" => "xyz"} =
               URI.decode_query(URI.parse(location).query)
    end

    @tag auth: [subject: Sake.Auth.StepUpTest.Subject]
    test "without reauthenticate/2, the error page says to sign in again", %{config: config} do
      client = public_client(config)
      conn = authorize(params(client, %{"acr_values" => "mfa"}), "mfa")

      # The subject module cannot say how anyone signed in: no acr meets.
      assert conn.status == 401
      assert conn.resp_body =~ "Sign in again to continue"
      assert ["DENY"] = get_resp_header(conn, "x-frame-options")
    end
  end

  describe "the tokens" do
    test "carry the code's acr and auth_time, and a refresh keeps auth_time", %{config: config} do
      client = public_client(config, %{grant_types: ["authorization_code", "refresh_token"]})
      query = params(client, %{"acr_values" => "mfa"})
      code = query |> authorize("mfa", 120) |> approve("mfa", 120) |> code()
      tokens = exchange(client, code)

      access = record(config, :access, tokens["access_token"])
      assert %{acr: "mfa", auth_time: %DateTime{} = signed_in} = access

      assert %{acr: "mfa", auth_time: ^signed_in} =
               record(config, :refresh, tokens["refresh_token"])

      conn =
        form("/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => tokens["refresh_token"],
          "client_id" => client.id
        })

      assert conn.status == 200
      refreshed = JSON.decode!(conn.resp_body)

      # A refresh is no new sign-in.
      assert %{acr: "mfa", auth_time: ^signed_in} =
               record(config, :access, refreshed["access_token"])

      assert %{acr: "mfa", auth_time: ^signed_in} =
               record(config, :refresh, refreshed["refresh_token"])
    end
  end

  describe "a pushed request" do
    @describetag auth: [par: true]

    test "takes acr_values and max_age, and is kept while the person signs in again", %{
      config: config
    } do
      client = public_client(config)
      conn = form("/par", params(client, %{"acr_values" => "mfa", "max_age" => "300"}))
      assert conn.status == 201
      %{"request_uri" => request_uri} = JSON.decode!(conn.resp_body)
      query = %{"client_id" => client.id, "request_uri" => request_uri}

      assert %{"acr" => "mfa", "return_to" => return_to} =
               query |> authorize("pwd") |> returned_to()

      assert URI.decode_query(URI.parse(return_to).query) == query

      # The same request_uri, once the person signed in with MFA.
      code = query |> authorize("mfa") |> approve("mfa") |> code()
      {module, state} = Sake.Auth.store(config)
      assert {:ok, %{acr: "mfa"}} = module.consume_code(state, Tokens.hash(code))

      # And it was taken then.
      assert authorize(query, "mfa").resp_body =~ "Request expired"
    end

    test "a bad max_age is refused at the push", %{config: config} do
      client = public_client(config)
      conn = form("/par", params(client, %{"max_age" => "-1"}))
      assert conn.status == 400
      assert %{"error" => "invalid_request"} = JSON.decode!(conn.resp_body)
    end
  end

  describe "the device grant" do
    @describetag auth: [device: true]

    defp device_page(method, params, acr, seconds) do
      conn(method, "/oauth/device", params)
      |> session("u1", acr, seconds)
      |> DeviceVerification.call(DeviceVerification.init([]))
    end

    defp enter(user_code, acr, seconds \\ 0) do
      form = device_page(:get, %{}, acr, seconds)
      [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, form.resp_body)
      device_page(:post, %{"user_code" => user_code, "request" => request}, acr, seconds)
    end

    test "takes acr_values, and the page sends the person to sign in again", %{config: config} do
      client =
        public_client(config, %{
          name: "Device CLI",
          redirect_uris: [],
          grant_types: [@device_code, "refresh_token"]
        })

      conn =
        form("/device_authorization", %{
          "client_id" => client.id,
          "resource" => @resource,
          "acr_values" => "mfa"
        })

      assert conn.status == 200
      %{"device_code" => device_code, "user_code" => user_code} = JSON.decode!(conn.resp_body)

      # A password sign-in: back to the login, then to the page with the
      # code filled in; the grant is still pending.
      assert %{"acr" => "mfa", "return_to" => return_to} =
               user_code |> enter("pwd") |> returned_to()

      assert return_to == "/oauth/device?" <> URI.encode_query(%{"user_code" => user_code})

      assert {:ok, %{grant: %{status: :pending}}} = Sake.Auth.Device.lookup(config, user_code)

      # With MFA: the consent page, approved; the tokens say so.
      conn = enter(user_code, "mfa", 20)
      assert conn.status == 200
      [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, conn.resp_body)
      done = device_page(:post, %{"request" => request, "decision" => "approve"}, "mfa", 20)
      assert done.resp_body =~ "Device connected"

      conn =
        form("/token", %{
          "grant_type" => @device_code,
          "device_code" => device_code,
          "client_id" => client.id
        })

      assert conn.status == 200, conn.resp_body
      tokens = JSON.decode!(conn.resp_body)

      assert %{acr: "mfa", auth_time: %DateTime{}} =
               record(config, :access, tokens["access_token"])
    end

    test "a bad max_age is refused at the device authorization endpoint", %{config: config} do
      client =
        public_client(config, %{redirect_uris: [], grant_types: [@device_code]})

      conn =
        form("/device_authorization", %{
          "client_id" => client.id,
          "resource" => @resource,
          "max_age" => "later"
        })

      assert conn.status == 400
      assert %{"error" => "invalid_request"} = JSON.decode!(conn.resp_body)
    end
  end

  describe "the resource" do
    defp mcp(token, method, params, server \\ Server, extra \\ []) do
      ModernClient.post(ModernClient.opts(server: server, auth: true), method, params,
        headers: [{"authorization", "Bearer " <> token}] ++ extra
      )
    end

    defp call(token, name, arguments, server \\ Server),
      do: mcp(token, "tools/call", %{"name" => name, "arguments" => arguments}, server)

    defp token(attrs) do
      {access, _, _} = issue(Sake.Auth.config(), attrs)
      access
    end

    defp ago(seconds),
      do: DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)

    test "a token without the acr is refused with RFC 9470's challenge" do
      pwd = token(%{scopes: ["issues:write"], acr: "pwd", auth_time: ago(10)})
      conn = call(pwd, "delete_repo", %{"name" => "x"})

      assert conn.status == 401

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer error="insufficient_user_authentication", error_description="A different authentication level is required", acr_values="mfa", max_age="300", resource_metadata="#{@metadata}")
             ]

      assert %{"error" => %{"message" => "Insufficient user authentication"}} =
               ModernClient.json(conn)
    end

    test "a sign-in too old is refused, a recent one with the acr is served" do
      old = token(%{scopes: ["issues:write"], acr: "mfa", auth_time: ago(600)})
      conn = call(old, "delete_repo", %{"name" => "x"})
      assert conn.status == 401
      assert [header] = get_resp_header(conn, "www-authenticate")
      assert header =~ ~s(error_description="More recent authentication is required")

      fresh = token(%{scopes: ["issues:write"], acr: "mfa", auth_time: ago(60)})
      conn = call(fresh, "delete_repo", %{"name" => "x"})
      assert conn.status == 200
      assert %{"result" => %{"content" => [%{"text" => "deleted x"}]}} = ModernClient.json(conn)

      # A token that says nothing of the sign-in meets no requirement.
      none = token(%{scopes: ["issues:write"]})
      assert call(none, "delete_repo", %{"name" => "x"}).status == 401
    end

    test "a token lacking the scope as well gets the sign-in challenge, naming the scope" do
      pwd = token(%{scopes: [], acr: "pwd", auth_time: ago(10)})
      conn = call(pwd, "delete_repo", %{"name" => "x"})
      assert conn.status == 401
      assert [header] = get_resp_header(conn, "www-authenticate")

      assert header =~
               ~s(acr_values="mfa", max_age="300", scope="issues:write", resource_metadata=)

      # With the sign-in met, the missing scope is the usual 403.
      mfa = token(%{scopes: [], acr: "mfa", auth_time: ago(10)})
      conn = call(mfa, "delete_repo", %{"name" => "x"})
      assert conn.status == 403

      assert [~s(Bearer error="insufficient_scope", scope="issues:write") <> _] =
               get_resp_header(conn, "www-authenticate")
    end

    test "components without a requirement answer as before, and the list shows them all" do
      pwd = token(%{scopes: ["issues:write"]})

      assert %{"result" => %{"content" => [%{"text" => "hi"}]}} =
               ModernClient.json(call(pwd, "echo", %{"text" => "hi"}))

      conn = mcp(pwd, "tools/list", %{})
      assert conn.status == 200
      names = Enum.map(ModernClient.json(conn)["result"]["tools"], & &1["name"])
      assert "delete_repo" in names
    end

    test "a resource's requirement applies to a read, and a stream request is refused the same way" do
      old = token(%{acr: "pwd", auth_time: ago(3_600)})
      conn = mcp(old, "resources/read", %{"uri" => "secret://vault"}, Server, [])
      assert conn.status == 401

      assert [
               ~s(Bearer error="insufficient_user_authentication", error_description="More recent authentication is required", max_age="600", resource_metadata=) <>
                 _
             ] =
               get_resp_header(conn, "www-authenticate")

      conn =
        ModernClient.post(
          ModernClient.opts(server: Server, auth: true),
          "tools/call",
          %{"name" => "delete_repo", "arguments" => %{"name" => "x"}},
          headers: [{"authorization", "Bearer " <> old}],
          meta: %{"progressToken" => 1}
        )

      assert conn.status == 401
    end

    test "a middleware asks for a requirement that depends on the arguments" do
      pwd = token(%{acr: "pwd", auth_time: ago(10)})
      assert call(pwd, "transfer", %{"amount" => 10}).status == 200

      conn = call(pwd, "transfer", %{"amount" => 5_000})
      assert conn.status == 401
      assert [header] = get_resp_header(conn, "www-authenticate")

      assert header ==
               ~s(Bearer error="insufficient_user_authentication", error_description="A different authentication level is required", acr_values="mfa", resource_metadata="#{@metadata}")

      mfa = token(%{acr: "mfa", auth_time: ago(10)})
      assert call(mfa, "transfer", %{"amount" => 5_000}).status == 200
    end

    test "a server's requirement applies to its components and its mounted ones" do
      assert %{acr_values: ["mfa", "hwk"], max_age: nil} = Strict.__sake__(:authentication)

      specs = Map.new(Strict.__sake__(:tools), &{&1.name, &1.authentication})
      assert specs["echo"] == %{acr_values: ["mfa", "hwk"], max_age: nil}
      assert specs["inner_delete_repo"] == %{acr_values: ["mfa"], max_age: 300}
      assert specs["inner_transfer"] == %{acr_values: ["mfa", "hwk"], max_age: nil}

      hwk = token(%{scopes: ["issues:write"], acr: "hwk", auth_time: ago(10)})
      assert call(hwk, "echo", %{"text" => "x"}, Strict).status == 200
      assert call(hwk, "inner_delete_repo", %{"name" => "x"}, Strict).status == 401

      pwd = token(%{acr: "pwd", auth_time: ago(10)})
      assert call(pwd, "echo", %{"text" => "x"}, Strict).status == 401
    end

    test "a requirement no acr of the server's meets does not compile" do
      assert_raise ArgumentError, ~r/has none of the server's/, fn ->
        defmodule Conflict do
          use Sake.Server, name: "c", version: "1", authentication: [acr: ["pwd"]]
          tools [Sake.Auth.StepUpTest.Delete]
        end
      end
    end
  end

  describe "the in-memory test client" do
    test "takes acr: and auth_time:, and answers a refusal as Sake.Client would" do
      import Sake.Test

      client =
        connect(Server, scopes: ["issues:write"], acr: "pwd", auth_time: DateTime.utc_now())

      assert {:error,
              {:insufficient_user_authentication,
               %Sake.Auth.Challenge{acr_values: ["mfa"], max_age: 300}}} =
               call_tool(client, "delete_repo", %{"name" => "x"})

      client =
        connect(Server, scopes: ["issues:write"], acr: "mfa", auth_time: DateTime.utc_now())

      assert {:ok, %{text: "deleted x"}} = call_tool(client, "delete_repo", %{"name" => "x"})

      # Without a token, nothing is gated.
      assert {:ok, _} = call_tool(connect(Server), "delete_repo", %{"name" => "x"})
    end
  end
end

defmodule Sake.Auth.StepUpExternalTest do
  # The tokens of an external authorization server carry the sign-in in
  # their `acr` and `auth_time` claims.
  use ExUnit.Case, async: false

  alias SakeTest.ModernClient

  setup do
    start_supervised!(
      {Sake,
       external_auth: [
         app: [
           issuer: "https://app.example.com",
           verify: Sake.Auth.StepUpTest.Tokens,
           servers: [Sake.Auth.StepUpTest.Server]
         ]
       ],
       secret_key_base: ModernClient.secret(),
       streams: false,
       tasks: false}
    )

    :ok
  end

  defp call(token) do
    ModernClient.post(
      ModernClient.opts(server: Sake.Auth.StepUpTest.Server, auth: :app),
      "tools/call",
      %{"name" => "delete_repo", "arguments" => %{"name" => "x"}},
      headers: [{"authorization", "Bearer " <> token}]
    )
  end

  test "acr and auth_time claims, as a DateTime or in seconds" do
    conn = call("mfa-now")
    assert conn.status == 200
    assert %{acr: "mfa", auth_time: %DateTime{}} = conn.assigns.sake_token

    assert [header] = get_resp_header(call("mfa-old"), "www-authenticate")
    assert header =~ ~s(error="insufficient_user_authentication")
    assert header =~ ~s(More recent authentication)

    assert [header] = get_resp_header(call("pwd"), "www-authenticate")
    assert header =~ ~s(acr_values="mfa", max_age="300")
  end

  defp get_resp_header(conn, name), do: Plug.Conn.get_resp_header(conn, name)
end
