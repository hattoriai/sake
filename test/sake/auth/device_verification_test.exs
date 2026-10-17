defmodule Sake.Auth.DeviceVerificationTest do
  # The device grant's two endpoints over Plug: the device authorization
  # endpoint, which a client calls, and the verification page, where a
  # signed-in person enters the user code and decides.
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.{DeviceVerification, RouterPlug}

  @moduletag auth: [device: true]

  @device_code "urn:ietf:params:oauth:grant-type:device_code"
  @resource "http://www.example.com/mcp"

  defp device_client(config) do
    public_client(config, %{
      name: "Device CLI",
      redirect_uris: [],
      grant_types: [@device_code, "refresh_token"]
    })
  end

  defp api(path, params) do
    conn(:post, path, URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> RouterPlug.call(RouterPlug.init([]))
  end

  defp start(client) do
    conn =
      api("/device_authorization", %{
        "client_id" => client.id,
        "scope" => "issues:read",
        "resource" => @resource
      })

    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp page(method, params, user \\ "u1") do
    conn(method, "/oauth/device", params)
    |> init_test_session(if(user, do: %{user_id: user}, else: %{}))
    |> DeviceVerification.call(DeviceVerification.init([]))
  end

  defp request(conn) do
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, conn.resp_body)
    request
  end

  defp enter(user_code, user \\ "u1") do
    form = page(:get, %{}, user)
    page(:post, %{"user_code" => user_code, "request" => request(form)}, user)
  end

  defp token(client, device_code) do
    conn =
      api("/token", %{
        "grant_type" => @device_code,
        "device_code" => device_code,
        "client_id" => client.id
      })

    {conn.status, JSON.decode!(conn.resp_body)}
  end

  describe "the device authorization endpoint" do
    test "answers as the token endpoint does, with no-store", %{config: config} do
      client = device_client(config)
      conn = api("/device_authorization", %{"client_id" => client.id, "resource" => @resource})

      assert conn.status == 200
      assert ["no-store"] = get_resp_header(conn, "cache-control")

      assert %{"device_code" => _, "user_code" => _, "interval" => 5} =
               JSON.decode!(conn.resp_body)

      conn = api("/device_authorization", %{"client_id" => "nobody"})
      assert conn.status == 401
      assert [~s(Basic realm="sake")] = get_resp_header(conn, "www-authenticate")
      assert %{"error" => "invalid_client"} = JSON.decode!(conn.resp_body)

      conn = api("/device_authorization", %{"client_id" => public_client(config).id})
      assert conn.status == 400
      assert %{"error" => "unauthorized_client"} = JSON.decode!(conn.resp_body)

      conn =
        conn(:get, "/oauth/device_authorization")
        |> Sake.Auth.DeviceAuthorization.call([])

      assert conn.status == 405
    end

    @tag auth: []
    test "is not there without device:", %{config: config} do
      assert api("/device_authorization", %{"client_id" => public_client(config).id}).status ==
               404

      assert page(:get, %{}).status == 404
    end
  end

  describe "the verification page" do
    test "code, consent, approval, then the tokens", %{config: config} do
      client = device_client(config)
      %{"user_code" => user_code, "device_code" => device_code} = start(client)

      assert {400, %{"error" => "authorization_pending"}} = token(client, device_code)

      # Prefilled from verification_uri_complete; nothing is looked up yet.
      form = page(:get, %{"user_code" => user_code})
      assert form.status == 200
      assert form.resp_body =~ ~s(name="user_code" value="#{user_code}")
      assert ["DENY"] = get_resp_header(form, "x-frame-options")
      assert ["no-store"] = get_resp_header(form, "cache-control")

      consent = page(:post, %{"user_code" => user_code, "request" => request(form)})
      assert consent.status == 200
      assert consent.resp_body =~ "Device CLI"
      assert consent.resp_body =~ "Read issues"
      assert consent.resp_body =~ user_code
      refute consent.resp_body =~ "sent back to"
      assert ["frame-ancestors 'none'"] = get_resp_header(consent, "content-security-policy")

      done = page(:post, %{"decision" => "approve", "request" => request(consent)})
      assert done.status == 200
      assert done.resp_body =~ "Device connected"

      # Polled too soon after the last poll; the grant waits for the interval.
      assert {400, %{"error" => "slow_down"}} = token(client, device_code)

      # Decided already: the same form cannot decide again.
      again = page(:post, %{"decision" => "deny", "request" => request(consent)})
      assert again.status == 400
      assert again.resp_body =~ "not valid"
    end

    test "a denial", %{config: config} do
      client = device_client(config)
      %{"user_code" => user_code, "device_code" => device_code} = start(client)

      consent = enter(user_code)
      done = page(:post, %{"decision" => "deny", "request" => request(consent)})
      assert done.status == 200
      assert done.resp_body =~ "Request denied"
      assert {400, %{"error" => "access_denied"}} = token(client, device_code)
    end

    test "an unknown code says no more than that it is not valid", %{config: config} do
      client = device_client(config)
      %{"user_code" => user_code} = start(client)

      for code <- ["BBBB-BBBB", "short", ""] do
        conn = enter(code)
        assert conn.status == 400
        assert conn.resp_body =~ "That code is not valid"
      end

      # A decided code reads the same as one that never existed.
      consent = enter(user_code)
      page(:post, %{"decision" => "approve", "request" => request(consent)})
      conn = enter(user_code)
      assert conn.status == 400
      assert conn.resp_body =~ "That code is not valid"
    end

    test "five code entries a minute, then none", %{config: config} do
      client = device_client(config)
      %{"user_code" => user_code} = start(client)

      for _ <- 1..5, do: assert(enter("BBBB-BBBB").status == 400)

      conn = enter(user_code)
      assert conn.status == 429
      assert conn.resp_body =~ "Too many codes"

      # Someone else is not held back.
      assert enter(user_code, "u2").status == 200
    end

    test "the forms are bound to the person, and to their own step", %{config: config} do
      client = device_client(config)
      %{"user_code" => user_code} = start(client)

      # Ana's code form, posted in Bo's session.
      form = page(:get, %{})
      conn = page(:post, %{"user_code" => user_code, "request" => request(form)}, "u2")
      assert conn.status == 400
      assert conn.resp_body =~ "no longer valid"

      # No form at all, or the code form's blob as a decision.
      assert page(:post, %{"user_code" => user_code}).status == 400
      assert page(:post, %{"decision" => "approve", "request" => request(form)}).status == 400

      # Ana's consent form, posted in Bo's session.
      consent = enter(user_code)
      conn = page(:post, %{"decision" => "approve", "request" => request(consent)}, "u2")
      assert conn.status == 400
    end

    test "nobody signed in", %{config: config} do
      device_client(config)
      conn = page(:get, %{}, nil)
      assert conn.status == 401
      assert conn.resp_body =~ "Sign in first"
    end

    test "a custom consent module without render_user_code/1 gets the default form", %{
      config: config
    } do
      defmodule Plain do
        @moduledoc false
        def render(assigns), do: "CONSENT #{assigns.flow} #{assigns.user_code}"
        def render_error(assigns), do: "ERR #{assigns.message}"
      end

      :persistent_term.put({Sake.Auth, :config}, %{config | consent: Plain})
      %{"user_code" => user_code} = start(device_client(config))

      assert page(:get, %{}).resp_body =~ ~s(name="user_code")
      assert enter(user_code).resp_body == "CONSENT device #{user_code}"
    end
  end

  describe "dynamic registration" do
    test "a device client registers without a redirect URI", %{config: config} do
      doc = %{"client_name" => "CLI", "grant_types" => [@device_code, "refresh_token"]}
      assert {:ok, response} = Sake.Auth.Registration.register(config, doc)
      assert response["grant_types"] == [@device_code, "refresh_token"]
      assert response["redirect_uris"] == []
      assert response["response_types"] == []

      assert {:error, "invalid_redirect_uri"} =
               Sake.Auth.Registration.register(config, %{
                 "client_name" => "CLI",
                 "grant_types" => ["authorization_code", @device_code]
               })
    end

    @tag auth: []
    test "only with device:", %{config: config} do
      assert {:error, "invalid_client_metadata"} =
               Sake.Auth.Registration.register(config, %{
                 "client_name" => "CLI",
                 "redirect_uris" => ["http://127.0.0.1:1/cb"],
                 "grant_types" => [@device_code]
               })
    end
  end
end
