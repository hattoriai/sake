defmodule Sake.Auth.DeviceTest.Subject do
  @moduledoc false
  # The development subject, with Bo (u2) holding `issues:read` only and
  # nobody allowed the `/locked/mcp` endpoint.
  @behaviour Sake.Auth.Subject

  @impl true
  defdelegate from_conn(conn), to: SakeDev.Subject
  @impl true
  defdelegate id(person), to: SakeDev.Subject
  @impl true
  defdelegate fetch(id), to: SakeDev.Subject
  @impl true
  defdelegate display(person), to: SakeDev.Subject

  @impl true
  def authorize_resource?(_person, resource), do: URI.parse(resource).path != "/locked/mcp"

  @impl true
  def scopes_for(%{id: "u2"}, _resource), do: ["issues:read"]
  def scopes_for(_person, _resource), do: :all
end

defmodule Sake.Auth.DeviceTest do
  # The device authorization grant (RFC 8628) without HTTP: the core's
  # start, the person's decision, and the token endpoint's polls.
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.{Device, DPoP, JWT, Metadata, TokenGrants, Tokens}

  @moduletag auth: [subject: Sake.Auth.DeviceTest.Subject, device: true]

  @device_code "urn:ietf:params:oauth:grant-type:device_code"
  @resource "http://www.example.com/mcp"

  defp device_client(config, attrs \\ %{}) do
    public_client(
      config,
      Map.merge(
        %{name: "Device CLI", redirect_uris: [], grant_types: [@device_code, "refresh_token"]},
        attrs
      )
    )
  end

  defp start(config, client, p \\ %{}) do
    {:ok, response} =
      Device.start(
        config,
        client,
        Map.merge(%{"scope" => "issues:read issues:write", "resource" => @resource}, p)
      )

    response
  end

  defp person(id) do
    {:ok, person} = SakeDev.Accounts.get(id)
    person
  end

  defp poll(config, client, device_code, proof \\ nil) do
    TokenGrants.exchange(
      config,
      %{"grant_type" => @device_code, "device_code" => device_code, "client_id" => client.id},
      [],
      proof
    )
  end

  # Moves the grant's last poll back past its interval, as if the client
  # had waited.
  defp waited(config, device_code) do
    {module, state} = Sake.Auth.store(config)
    hash = Tokens.hash(device_code)
    [{^hash, grant, fence}] = :ets.lookup(Sake.Auth.Store.ETS.DeviceGrants, hash)
    last = grant.last_polled_at && DateTime.add(grant.last_polled_at, -grant.interval, :second)
    :ets.insert(Sake.Auth.Store.ETS.DeviceGrants, {hash, %{grant | last_polled_at: last}, fence})
    {module, state}
  end

  describe "start/3" do
    test "stores the grant hashed and answers RFC 8628 §3.2", %{config: config} do
      client = device_client(config)
      response = start(config, client)

      assert %{
               "device_code" => device_code,
               "user_code" => user_code,
               "verification_uri" => "http://www.example.com/oauth/device",
               "verification_uri_complete" => complete,
               "expires_in" => 600,
               "interval" => 5
             } = response

      assert user_code =~ ~r/\A[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}\z/
      assert complete == "http://www.example.com/oauth/device?user_code=" <> user_code

      # Neither code is kept as it is: the store knows their digests only.
      {:ok, code} = Device.normalize(user_code)
      [{hash, grant, :live}] = :ets.tab2list(Sake.Auth.Store.ETS.DeviceGrants)
      assert hash == Tokens.hash(device_code)
      assert grant.user_code_hash == Device.user_code_hash(config, code)
      refute grant.user_code_hash in [code, Tokens.hash(code)]

      assert %{
               status: :pending,
               client_id: client_id,
               scopes: ["issues:read", "issues:write"],
               resource: @resource,
               interval: 5
             } = grant

      assert client_id == client.id
    end

    @tag auth: [subject: Sake.Auth.DeviceTest.Subject, device: [expires_in: 60, interval: 2]]
    test "takes its expiry and interval from the configuration", %{config: config} do
      assert %{"expires_in" => 60, "interval" => 2} = start(config, device_client(config))
    end

    test "validates the request as an authorization request", %{config: config} do
      code_only = public_client(config)

      assert {:error, "unauthorized_client",
              "The client may not use the device authorization grant"} =
               Device.start(config, code_only, %{"resource" => @resource})

      client = device_client(config)

      assert {:error, "invalid_scope", "Unknown scope: nope"} =
               Device.start(config, client, %{"scope" => "nope", "resource" => @resource})

      assert {:error, "invalid_target", _} =
               Device.start(config, client, %{"resource" => "https://elsewhere.example/mcp"})
    end

    test "authorize/3 authenticates the client first", %{config: config} do
      client = device_client(config)

      assert {:error, 401, "invalid_client", _} =
               Device.authorize(config, %{"client_id" => "nobody"}, [])

      assert {:ok, %{"device_code" => _}} =
               Device.authorize(config, %{"client_id" => client.id, "resource" => @resource}, [])
    end
  end

  test "user codes are normalized: case, dashes and spaces do not count" do
    assert {:ok, "BCDFGHJK"} = Device.normalize("bcdf-ghjk")
    assert {:ok, "BCDFGHJK"} = Device.normalize(" BCDF GHJK ")
    assert :error = Device.normalize("BCDF-GHJ")
    # A letter outside the alphabet is not dropped: the code is wrong.
    assert :error = Device.normalize("ABCD-FGHJ")
    assert :error = Device.normalize(nil)
  end

  describe "the person's decision" do
    test "the consent page's assigns for the device flow", %{config: config} do
      client = device_client(config)
      %{"user_code" => user_code} = start(config, client)

      assert {:consent, assigns} =
               Device.prompt(config, String.downcase(user_code), person("u1"))

      assert %{
               flow: :device,
               user_code: ^user_code,
               client_name: "Device CLI",
               redirect_host: nil,
               loopback?: nil,
               scopes: [{"issues:read", _}, {"issues:write", _}],
               resource: @resource
             } = assigns

      assert :error = Device.prompt(config, "BBBB-BBBB", person("u1"))
    end

    test "an approval goes through Grant: narrowed, and the consent remembered", %{
      config: config
    } do
      client = device_client(config)
      %{"user_code" => user_code, "device_code" => device_code} = start(config, client)

      assert {:consent, %{scopes: [{"issues:read", _}]}} =
               Device.prompt(config, user_code, person("u2"))

      assert :ok = Device.decide(config, user_code, person("u2"), :approve)

      # Decided once: the code is no longer valid on the page.
      assert :error = Device.decide(config, user_code, person("u2"), :approve)
      assert :error = Device.prompt(config, user_code, person("u2"))

      {module, state} = Sake.Auth.store(config)

      assert {:ok, %{scopes: ["issues:read"]}} =
               module.get_consent(state, "u2", client.id, @resource)

      assert {:ok, %{"access_token" => access, "refresh_token" => _, "scope" => "issues:read"}} =
               poll(config, client, device_code)

      assert {:ok, %{subject_id: "u2", scopes: ["issues:read"], family_id: family}} =
               module.get_token(state, :access, Tokens.hash(access))

      assert family == Tokens.hash(device_code)
    end

    test "a remembered consent still shows the page", %{config: config} do
      client = device_client(config)
      %{"user_code" => first} = start(config, client)
      :ok = Device.decide(config, first, person("u1"), :approve)

      %{"user_code" => second} = start(config, client)
      assert {:consent, %{flow: :device}} = Device.prompt(config, second, person("u1"))
    end

    test "a denial, and a resource the person may not authorize, deny the grant", %{
      config: config
    } do
      client = device_client(config)
      %{"user_code" => user_code, "device_code" => device_code} = start(config, client)
      assert :ok = Device.decide(config, user_code, person("u1"), :deny)
      assert {:error, 400, "access_denied", _} = poll(config, client, device_code)

      %{"user_code" => user_code, "device_code" => device_code} =
        start(config, client, %{"resource" => "http://www.example.com/locked/mcp"})

      assert {:error, "access_denied", "You may not authorize this resource"} =
               Device.prompt(config, user_code, person("u1"))

      assert {:error, 400, "access_denied", _} = poll(config, client, device_code)
    end

    test "five code entries a minute for each person", %{config: config} do
      for _ <- 1..5, do: assert(:ok = Device.attempt(config, "u1"))
      assert :limited = Device.attempt(config, "u1")
      assert :ok = Device.attempt(config, "u2")
    end
  end

  describe "the token endpoint's device code grant" do
    test "pending, slow_down, then the tokens once; a replay revokes them", %{config: config} do
      client = device_client(config)
      %{"user_code" => user_code, "device_code" => device_code} = start(config, client)

      assert {:error, 400, "authorization_pending", _} = poll(config, client, device_code)
      assert {:error, 400, "slow_down", _} = poll(config, client, device_code)

      :ok = Device.decide(config, user_code, person("u1"), :approve)
      waited(config, device_code)
      assert {:ok, %{"access_token" => access}} = poll(config, client, device_code)

      waited(config, device_code)

      assert {:error, 400, "invalid_grant", "The device code was already used"} =
               poll(config, client, device_code)

      {module, state} = Sake.Auth.store(config)

      assert {:ok, %{revoked_at: %DateTime{}}} =
               module.get_token(state, :access, Tokens.hash(access))
    end

    test "an unknown code, another client's, an expired one", %{config: config} do
      client = device_client(config)
      other = device_client(config, %{name: "Other"})
      %{"device_code" => device_code} = start(config, client)

      assert {:error, 400, "invalid_grant", "The device code is invalid"} =
               poll(config, client, "unknown")

      assert {:error, 400, "invalid_grant", _} = poll(config, other, device_code)

      assert {:error, 400, "invalid_request", "device_code is required"} =
               TokenGrants.exchange(
                 config,
                 %{"grant_type" => @device_code, "client_id" => client.id},
                 [],
                 nil
               )

      hash = Tokens.hash(device_code)
      [{^hash, grant, fence}] = :ets.lookup(Sake.Auth.Store.ETS.DeviceGrants, hash)
      past = DateTime.add(DateTime.utc_now(), -1)
      :ets.insert(Sake.Auth.Store.ETS.DeviceGrants, {hash, %{grant | expires_at: past}, fence})
      assert {:error, 400, "expired_token", _} = poll(config, client, device_code)
    end

    test "a client not registered for the grant may not use it", %{config: config} do
      client = public_client(config)

      assert {:error, 400, "unauthorized_client", _} = poll(config, client, "anything")
    end

    test "the tokens are bound to the DPoP key of the token request", %{config: config} do
      client = device_client(config)
      %{"user_code" => user_code, "device_code" => device_code} = start(config, client)
      :ok = Device.decide(config, user_code, person("u1"), :approve)

      {pem, jkt} = Sake.Auth.dpop_key()
      {:ok, key} = JWT.private_key(pem)
      proof = DPoP.proof(key, "POST", "http://www.example.com/oauth/token")
      {:ok, checked} = TokenGrants.proof(config, [proof])

      assert {:ok,
              %{"token_type" => "DPoP", "access_token" => access, "refresh_token" => refresh}} =
               poll(config, client, device_code, checked)

      {module, state} = Sake.Auth.store(config)
      assert {:ok, %{jkt: ^jkt}} = module.get_token(state, :access, Tokens.hash(access))
      # A public client's refresh token is bound to the key too.
      assert {:ok, %{jkt: ^jkt}} = module.get_token(state, :refresh, Tokens.hash(refresh))
    end

    @tag auth: [subject: Sake.Auth.DeviceTest.Subject]
    test "without device:, the grant is not offered", %{config: config} do
      assert {:error, 400, "unsupported_grant_type", _} =
               TokenGrants.exchange(
                 config,
                 %{"grant_type" => @device_code, "device_code" => "x"},
                 [],
                 nil
               )
    end
  end

  describe "metadata" do
    test "the device endpoint and the grant type", %{config: config} do
      m = Metadata.authorization_server(config)

      assert m["device_authorization_endpoint"] ==
               "http://www.example.com/oauth/device_authorization"

      assert List.last(m["grant_types_supported"]) == @device_code
    end

    @tag auth: [subject: Sake.Auth.DeviceTest.Subject]
    test "neither without device:", %{config: config} do
      m = Metadata.authorization_server(config)
      refute Map.has_key?(m, "device_authorization_endpoint")
      refute @device_code in m["grant_types_supported"]
    end
  end

  test "device: is checked when Sake starts" do
    base = [subject: SakeDev.Subject, issuer: "https://x.example", secret: "s"]

    assert_raise ArgumentError, ~r/device: takes/, fn ->
      Sake.Auth.Config.new(base ++ [device: [interval: 0]])
    end

    assert_raise ArgumentError, ~r/needs the Sake secret/, fn ->
      Sake.Auth.Config.new(Keyword.delete(base, :secret) ++ [device: true])
    end

    assert %{device: %{expires_in: 600, interval: 5}} =
             Sake.Auth.Config.new(base ++ [device: true])
  end
end
