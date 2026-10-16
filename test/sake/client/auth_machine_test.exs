defmodule Sake.Client.AuthMachineTest do
  use ExUnit.Case, async: true

  alias Sake.Auth.JWT
  alias Sake.Client
  alias Sake.Client.Auth.Grant
  alias SakeTest.{FakeOAuth, HTTP, Keys}

  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"

  setup do
    %{state: FakeOAuth.state()}
  end

  defp serve(%{state: state}, opts \\ []) do
    base = HTTP.start({FakeOAuth, [test: self(), state: state] ++ opts})
    {base, base <> "/mcp"}
  end

  defp requests(acc \\ []) do
    receive do
      {:fake_oauth, method, path, params, headers} ->
        requests([{method, path, params, Map.new(headers)} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp paths(requests), do: Enum.map(requests, fn {m, p, _, _} -> "#{m} #{p}" end)

  defp posts(requests, path),
    do: for({"POST", ^path, params, headers} <- requests, do: {params, headers})

  defp basic(id, secret), do: "Basic " <> Base.encode64(id <> ":" <> secret)

  describe "client credentials" do
    test "with a secret: discovery, then the token endpoint, and no browser", ctx do
      {base, url} = serve(ctx)

      auth = [grant: :client_credentials, client_id: "svc", client_secret: "s3cret"]
      assert {:ok, session} = Client.connect(url, auth: auth)
      requests = requests()

      assert paths(requests) == [
               "POST /mcp",
               "GET /.well-known/oauth-protected-resource/mcp",
               "GET /.well-known/oauth-authorization-server",
               "POST /token",
               "POST /mcp"
             ]

      # The fake server lists only `none`; a secret goes by RFC 8414's
      # default, HTTP Basic, unless the server says otherwise.
      [{token, headers}] = posts(requests, "/token")
      assert token == %{"grant_type" => "client_credentials", "resource" => base <> "/mcp"}
      assert headers["authorization"] == basic("svc", "s3cret")

      assert session.auth.token["refresh_token"] == nil
      assert {:ok, %{text: "echo"}, _session} = Client.call_tool(session, "echo", %{})
    end

    test "client_secret_post, and the challenged scopes", ctx do
      {_base, url} =
        serve(ctx,
          challenge_scope: "files:read",
          metadata: %{
            "token_endpoint_auth_methods_supported" => ["client_secret_post"],
            "scopes_supported" => ["files:read", "offline_access"]
          }
        )

      auth = [grant: :client_credentials, client_id: "svc", client_secret: "s3cret"]
      assert {:ok, _session} = Client.connect(url, auth: auth)
      [{token, headers}] = posts(requests(), "/token")

      assert %{"client_id" => "svc", "client_secret" => "s3cret", "scope" => "files:read"} = token
      refute Map.has_key?(headers, "authorization")
    end

    test "with a private key: a fresh signed assertion for each request", ctx do
      {base, url} = serve(ctx, expires_in: 3600)
      pem = Keys.pem(:ec)
      {:ok, key} = JWT.private_key(pem)
      jwk = JWT.public_jwk(key)

      auth = [grant: :client_credentials, client_id: "svc", private_key: pem]
      assert {:ok, session} = Client.connect(url, auth: auth)

      # An expiring token is replaced before the next request: the grant
      # runs again, straight at the token endpoint.
      session = put_in(session.auth.token["expires_at"], System.system_time(:second))
      assert {:ok, _result, _session} = Client.call_tool(session, "echo", %{})
      requests = requests()

      assert Enum.drop(paths(requests), 5) == ["POST /token", "POST /mcp"]

      [{first, headers}, {second, _}] = posts(requests, "/token")
      refute Map.has_key?(headers, "authorization") or Map.has_key?(first, "client_id")

      assert first["client_assertion_type"] ==
               "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

      for params <- [first, second] do
        assert {:ok, claims} =
                 JWT.verify(params["client_assertion"], [jwk],
                   iss: "svc",
                   aud: base,
                   required: ["iss", "sub", "exp", "iat", "jti"]
                 )

        assert claims["sub"] == "svc"
        assert claims["exp"] - claims["iat"] <= 60
      end

      assert JWT.peek(first["client_assertion"]) |> elem(1) |> Map.get("alg") == "ES256"

      {:ok, _, a} = JWT.peek(first["client_assertion"])
      {:ok, _, b} = JWT.peek(second["client_assertion"])
      assert a["jti"] != b["jti"]
    end

    test "an RSA key signs RS256, or PS256 when asked", ctx do
      {_base, url} = serve(ctx)
      pem = Keys.pem(:rsa)

      assert {:ok, _} =
               Client.connect(url,
                 auth: [grant: :client_credentials, client_id: "svc", private_key: {pem, "PS256"}]
               )

      [{token, _}] = posts(requests(), "/token")
      assert {:ok, %{"alg" => "PS256"}, _} = JWT.peek(token["client_assertion"])
    end

    test "needs only a token endpoint, not an authorization endpoint or PKCE", ctx do
      {_base, url} =
        serve(ctx,
          metadata: %{"authorization_endpoint" => nil, "code_challenge_methods_supported" => nil}
        )

      auth = [grant: :client_credentials, client_id: "svc", client_secret: "s"]
      assert {:ok, _session} = Client.connect(url, auth: auth)
    end

    test "a 403 runs the grant again for the union of the scopes", ctx do
      {_base, url} =
        serve(ctx,
          call_scopes: ["files:write"],
          metadata: %{"scopes_supported" => ["files:read", "files:write", "offline_access"]},
          challenge_scope: "files:read"
        )

      auth = [grant: :client_credentials, client_id: "svc", client_secret: "s"]
      assert {:ok, session} = Client.connect(url, auth: auth)
      assert {:ok, %{text: "echo"}, _session} = Client.call_tool(session, "echo", %{})

      scopes = for {params, _} <- posts(requests(), "/token"), do: params["scope"]
      assert scopes == ["files:read", "files:read files:write"]
    end

    test "a refused grant ends the flow; the server is not asked again", ctx do
      {_base, url} = serve(ctx, grant_error: "invalid_client")
      auth = [grant: :client_credentials, client_id: "svc", client_secret: "wrong"]

      assert {:error, {:auth, {:token_failed, 400, %{"error" => "invalid_client"}}}} =
               Client.connect(url, auth: auth)

      assert length(posts(requests(), "/token")) == 1
    end
  end

  describe "the JWT bearer grant" do
    test "presents the workload's JWT, with no client authentication", ctx do
      {base, url} = serve(ctx)
      test = self()

      assertion = fn target ->
        send(test, {:asked, target})
        {:ok, "workload.jwt.value"}
      end

      assert {:ok, _session} =
               Client.connect(url, auth: [grant: :jwt_bearer, assertion: assertion])

      assert_received {:asked, %{issuer: ^base, resource: resource}}
      assert resource == base <> "/mcp"

      [{token, headers}] = posts(requests(), "/token")

      assert token == %{
               "grant_type" => @jwt_bearer,
               "assertion" => "workload.jwt.value",
               "resource" => base <> "/mcp"
             }

      refute Map.has_key?(headers, "authorization")
    end

    test "a refused JWT is reported, not retried or traded for another grant", ctx do
      {_base, url} = serve(ctx, grant_error: "invalid_grant")

      assert {:error, {:auth, {:token_failed, 400, %{"error" => "invalid_grant"}}}} =
               Client.connect(url,
                 auth: [grant: :jwt_bearer, assertion: "expired.jwt.x", client_id: "w"]
               )

      requests = requests()
      assert [{%{"client_id" => "w"}, _}] = posts(requests, "/token")
      refute Enum.any?(requests, &match?({_, "/authorize", _, _}, &1))
      refute Enum.any?(requests, &match?({_, "/register", _, _}, &1))
    end

    test "a function that fails stops the flow", ctx do
      {_base, url} = serve(ctx)

      assert {:error, {:auth, {:assertion, :no_token}}} =
               Client.connect(url,
                 auth: [grant: :jwt_bearer, assertion: fn _ -> {:error, :no_token} end]
               )

      assert posts(requests(), "/token") == []
    end
  end

  describe "enterprise-managed authorization" do
    test "exchanges the ID token at the IdP, then presents the ID-JAG", ctx do
      {base, url} = serve(ctx)

      auth = [
        grant: :enterprise,
        client_id: "agent",
        client_secret: "agent-secret",
        id_token: "id.token.x",
        idp: [
          token_endpoint: base <> "/idp/token",
          client_id: "idp-agent",
          client_secret: "idp-secret"
        ]
      ]

      assert {:ok, session} = Client.connect(url, auth: auth)
      requests = requests()

      [{exchange, idp_headers}] = posts(requests, "/idp/token")

      assert exchange == %{
               "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
               "requested_token_type" => "urn:ietf:params:oauth:token-type:id-jag",
               "audience" => base,
               "resource" => base <> "/mcp",
               "subject_token" => "id.token.x",
               "subject_token_type" => "urn:ietf:params:oauth:token-type:id_token"
             }

      assert idp_headers["authorization"] == basic("idp-agent", "idp-secret")

      [{grant, headers}] = posts(requests, "/token")
      assert grant["grant_type"] == @jwt_bearer and grant["assertion"] == "jag-id.token.x"
      assert headers["authorization"] == basic("agent", "agent-secret")
      assert session.auth.token["access_token"]
    end

    test "finds the IdP's token endpoint from its issuer", ctx do
      {base, url} = serve(ctx)

      auth = [
        grant: :enterprise,
        client_id: "agent",
        id_token: fn _ -> {:ok, "id.token.y"} end,
        idp: [issuer: base <> "/idp", client_id: "idp-agent", client_secret: "idp-secret"]
      ]

      assert {:ok, _session} = Client.connect(url, auth: auth)
      requests = requests()
      assert "GET /.well-known/oauth-authorization-server/idp" in paths(requests)

      # The IdP's metadata lists only client_secret_post.
      [{exchange, _}] = posts(requests, "/idp/token")
      assert %{"client_id" => "idp-agent", "client_secret" => "idp-secret"} = exchange

      # A public client at the authorization server sends its client_id.
      [{grant, _}] = posts(requests, "/token")
      assert grant["client_id"] == "agent" and grant["assertion"] == "jag-id.token.y"
    end

    test "a refusal at the IdP ends the flow", ctx do
      {base, url} = serve(ctx, idp_error: "access_denied")

      auth = [
        grant: :enterprise,
        client_id: "agent",
        id_token: "id.token.x",
        idp: [token_endpoint: base <> "/idp/token", client_id: "idp-agent"]
      ]

      assert {:error, {:auth, {:token_exchange_failed, 400, %{"error" => "access_denied"}}}} =
               Client.connect(url, auth: auth)

      assert posts(requests(), "/token") == []
    end
  end

  describe "enterprise-managed authorization with SAML" do
    @exchange "urn:ietf:params:oauth:grant-type:token-exchange"
    @refresh_type "urn:ietf:params:oauth:token-type:refresh_token"

    defmodule Store do
      @moduledoc false
      @behaviour Sake.Client.Auth.Store

      @impl true
      def fetch(agent, key), do: Agent.get(agent, &Map.fetch(&1, key))

      @impl true
      def put(agent, key, value), do: Agent.update(agent, &Map.put(&1, key, value))
    end

    defp saml_auth(base, extra \\ []) do
      Keyword.merge(
        [
          grant: :enterprise,
          client_id: "agent",
          saml_assertion: "PHNhbWw6QXNzZXJ0aW9uLz4",
          idp: [issuer: base <> "/idp", client_id: "idp-agent", client_secret: "idp-secret"]
        ],
        extra
      )
    end

    defp expire(session),
      do: put_in(session.auth.token["expires_at"], System.system_time(:second))

    test "the assertion is traded for the IdP's refresh token, and that for the ID-JAG", ctx do
      {base, url} = serve(ctx)

      assert {:ok, session} = Client.connect(url, auth: saml_auth(base))
      requests = requests()

      [{saml, _}, {exchange, _}] = posts(requests, "/idp/token")

      # draft-ietf-oauth-identity-assertion-authz-grant §4.5: a token
      # exchange for a refresh token, the IdP itself as the audience.
      assert saml == %{
               "grant_type" => @exchange,
               "requested_token_type" => @refresh_type,
               "audience" => base <> "/idp",
               "subject_token" => "PHNhbWw6QXNzZXJ0aW9uLz4",
               "subject_token_type" => "urn:ietf:params:oauth:token-type:saml2",
               "client_id" => "idp-agent",
               "client_secret" => "idp-secret"
             }

      "idp-refresh-" <> _ = refresh = session.auth.idp_token["refresh_token"]

      assert Map.drop(exchange, ["client_id", "client_secret"]) == %{
               "grant_type" => @exchange,
               "requested_token_type" => "urn:ietf:params:oauth:token-type:id-jag",
               "audience" => base,
               "resource" => base <> "/mcp",
               "subject_token" => refresh,
               "subject_token_type" => @refresh_type
             }

      [{grant, _}] = posts(requests, "/token")
      assert grant["grant_type"] == @jwt_bearer
      assert grant["assertion"] == "jag-PHNhbWw6QXNzZXJ0aW9uLz4"
      assert {:ok, %{text: "echo"}, _session} = Client.call_tool(session, "echo", %{})
    end

    test "a later authorization uses the kept refresh token, without the assertion", ctx do
      {base, url} = serve(ctx, expires_in: 3600)
      test = self()

      assertion = fn target ->
        send(test, {:asked, target})
        {:ok, "c2FtbA"}
      end

      assert {:ok, session} =
               Client.connect(url, auth: saml_auth(base, saml_assertion: assertion))

      assert_received {:asked, %{issuer: ^base}}
      refresh = session.auth.idp_token["refresh_token"]
      _ = requests()

      assert {:ok, _result, _session} = Client.call_tool(expire(session), "echo", %{})
      refute_received {:asked, _}

      requests = requests()
      assert [{%{"subject_token" => ^refresh}, _}] = posts(requests, "/idp/token")
      assert [{%{"assertion" => "jag-c2FtbA"}, _}] = posts(requests, "/token")
    end

    test "the refresh token is kept in the store, for the next session", ctx do
      {base, url} = serve(ctx)
      {:ok, store} = Agent.start_link(fn -> %{} end)
      auth = saml_auth(base, store: {Store, store})

      assert {:ok, session} = Client.connect(url, auth: auth)
      issuer = base <> "/idp"
      kept = Agent.get(store, & &1[{:idp, issuer}])

      assert kept == %{
               "refresh_token" => session.auth.idp_token["refresh_token"],
               "expires_at" => nil,
               "issuer" => issuer,
               "client_id" => "idp-agent"
             }

      # A new session without the MCP token: the ID-JAG comes from the
      # stored refresh token, and the assertion is not traded again.
      Agent.update(store, &Map.delete(&1, {:token, url}))
      _ = requests()

      assert {:ok, _session} =
               Client.connect(url, auth: Keyword.put(auth, :saml_assertion, "unused"))

      assert [{%{"subject_token_type" => @refresh_type}, _}] =
               posts(requests(), "/idp/token")

      # It belongs to the client at the IdP it was issued to.
      Agent.update(store, &Map.delete(&1, {:token, url}))
      other = put_in(auth[:idp][:client_id], "someone-else")
      assert {:ok, _session} = Client.connect(url, auth: other)

      assert [{%{"subject_token_type" => "urn:ietf:params:oauth:token-type:saml2"}, _}, _] =
               posts(requests(), "/idp/token")
    end

    test "a refresh token the IdP refuses is dropped, and the assertion traded again", ctx do
      {base, url} = serve(ctx, expires_in: 3600)

      assert {:ok, session} = Client.connect(url, auth: saml_auth(base))
      old = session.auth.idp_token["refresh_token"]
      Agent.update(ctx.state, &%{&1 | idp_refresh: %{}})
      _ = requests()

      assert {:ok, _result, session} = Client.call_tool(expire(session), "echo", %{})

      assert [
               {%{"subject_token" => ^old}, _},
               {%{"subject_token_type" => "urn:ietf:params:oauth:token-type:saml2"}, _},
               {%{"subject_token" => new}, _}
             ] = posts(requests(), "/idp/token")

      assert new != old and session.auth.idp_token["refresh_token"] == new
    end

    test "an expired refresh token is not used", ctx do
      {base, url} = serve(ctx, expires_in: 3600, idp_refresh_expires_in: 10)

      assert {:ok, session} = Client.connect(url, auth: saml_auth(base))
      assert is_integer(session.auth.idp_token["expires_at"])
      _ = requests()

      # Ten seconds is inside the expiry margin: the assertion goes again.
      assert {:ok, _result, _session} = Client.call_tool(expire(session), "echo", %{})

      assert [{%{"subject_token_type" => "urn:ietf:params:oauth:token-type:saml2"}, _}, _] =
               posts(requests(), "/idp/token")
    end

    test "the refresh token may come in access_token, as RFC 8693 carries it", ctx do
      {base, url} = serve(ctx, saml_in: :access_token)

      assert {:ok, session} = Client.connect(url, auth: saml_auth(base))
      assert "idp-refresh-" <> _ = session.auth.idp_token["refresh_token"]
    end

    test "a refusal at the IdP ends the flow", ctx do
      {base, url} = serve(ctx, idp_error: "invalid_grant")

      assert {:error, {:auth, {:saml_exchange_failed, 400, %{"error" => "invalid_grant"}}}} =
               Client.connect(url, auth: saml_auth(base))

      assert [_] = posts(requests(), "/idp/token")
    end
  end

  describe "client_secret_jwt" do
    @secret "a-client-secret-of-32-bytes-or-more"
    @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

    defp hs256_claims(jwt) do
      [h, c, _] = String.split(jwt, ".")

      {JSON.decode!(Base.url_decode64!(h, padding: false)),
       JSON.decode!(Base.url_decode64!(c, padding: false))}
    end

    test "at the authorization server, when asked for", ctx do
      {base, url} = serve(ctx, hmac_secret: @secret)

      auth = [
        grant: :client_credentials,
        client_id: "svc",
        client_secret: @secret,
        token_endpoint_auth_method: "client_secret_jwt"
      ]

      # The fake server checks the HMAC and the claims, and refuses
      # anything else with invalid_client.
      assert {:ok, _session} = Client.connect(url, auth: auth)
      [{token, headers}] = posts(requests(), "/token")

      refute Map.has_key?(headers, "authorization")
      refute Map.has_key?(token, "client_secret") or Map.has_key?(token, "client_id")
      assert token["client_assertion_type"] == @assertion_type

      {header, claims} = hs256_claims(token["client_assertion"])
      assert header == %{"alg" => "HS256"}
      assert %{"iss" => "svc", "sub" => "svc", "aud" => ^base} = claims
      assert claims["exp"] - claims["iat"] <= 60

      # A wrong secret is refused by the server that checks it.
      auth = Keyword.put(auth, :client_secret, String.reverse(@secret))

      assert {:error, {:auth, {:token_failed, 401, %{"error" => "invalid_client"}}}} =
               Client.connect(url, auth: auth)
    end

    test "chosen for a server that lists it as its only secret method", ctx do
      {_base, url} =
        serve(ctx,
          hmac_secret: @secret,
          metadata: %{"token_endpoint_auth_methods_supported" => ["client_secret_jwt"]}
        )

      auth = [grant: :client_credentials, client_id: "svc", client_secret: @secret]
      assert {:ok, session} = Client.connect(url, auth: auth)
      assert session.auth.token["token_endpoint_auth_method"] == "client_secret_jwt"

      # A secret too short to key HS256 goes as HTTP Basic instead.
      auth = Keyword.put(auth, :client_secret, "short")
      _ = requests()
      assert {:ok, _session} = Client.connect(url, auth: auth)
      [{_, headers}] = posts(requests(), "/token")
      assert headers["authorization"] == basic("svc", "short")
    end

    test "at the identity provider, for the token exchange", ctx do
      {base, url} = serve(ctx, hmac_secret: @secret, idp_auth_methods: ["client_secret_jwt"])

      auth = [
        grant: :enterprise,
        client_id: "agent",
        id_token: "id.token.x",
        idp: [issuer: base <> "/idp", client_id: "idp-agent", client_secret: @secret]
      ]

      assert {:ok, _session} = Client.connect(url, auth: auth)
      [{exchange, _}] = posts(requests(), "/idp/token")
      refute Map.has_key?(exchange, "client_secret")

      {_header, claims} = hs256_claims(exchange["client_assertion"])
      assert %{"iss" => "idp-agent", "sub" => "idp-agent"} = claims
      assert claims["aud"] == base <> "/idp"

      # Named explicitly, against a provider given by its token endpoint
      # only: the assertion is then for that endpoint.
      auth =
        put_in(auth[:idp],
          token_endpoint: base <> "/idp/token",
          client_id: "idp-agent",
          client_secret: @secret,
          token_endpoint_auth_method: "client_secret_jwt"
        )

      assert {:ok, _session} = Client.connect(url, auth: auth)
      [{exchange, _}] = posts(requests(), "/idp/token")
      assert {_, %{"aud" => aud}} = hs256_claims(exchange["client_assertion"])
      assert aud == base <> "/idp/token"
    end

    test "the assertion is an HMAC over the secret, made with :crypto alone" do
      # No jose, and no key: verifying it by hand with the secret is all
      # it takes.
      {params, []} =
        Grant.authenticate([], %{
          "client_id" => "c",
          "client_secret" => @secret,
          "token_endpoint_auth_method" => "client_secret_jwt",
          "issuer" => "https://as.example"
        })

      [h, c, mac] = String.split(params[:client_assertion], ".")

      assert Base.url_decode64!(mac, padding: false) ==
               :crypto.mac(:hmac, :sha256, @secret, h <> "." <> c)
    end
  end

  describe "the authorization extension in the client's capabilities" do
    @client_credentials "io.modelcontextprotocol/oauth-client-credentials"
    @enterprise "io.modelcontextprotocol/enterprise-managed-authorization"

    defp mcp_bodies(requests), do: for({"POST", "/mcp", body, _} <- requests, do: body)

    defp declared(%{"params" => %{"_meta" => meta}}),
      do: meta["io.modelcontextprotocol/clientCapabilities"]["extensions"] || %{}

    test "client credentials are declared in every modern request's _meta", ctx do
      {_base, url} = serve(ctx)

      auth = [grant: :client_credentials, client_id: "svc", client_secret: "s3cret"]
      assert {:ok, session} = Client.connect(url, auth: auth, ui: true)
      assert {:ok, _result, _session} = Client.call_tool(session, "echo", %{})

      bodies = mcp_bodies(requests())

      assert Enum.map(bodies, & &1["method"]) == [
               "server/discover",
               "server/discover",
               "tools/call"
             ]

      for body <- bodies do
        ext = declared(body)
        assert ext[@client_credentials] == %{}
        refute Map.has_key?(ext, @enterprise)
        # Next to MCP Apps and the tasks extension, not in place of them.
        assert Map.has_key?(ext, Sake.UI.extension())
        assert Map.has_key?(ext, Sake.Tasks.extension())
      end
    end

    test "enterprise-managed authorization is declared in the legacy initialize", ctx do
      {base, url} = serve(ctx, legacy: true)

      auth = [
        grant: :enterprise,
        client_id: "agent",
        id_token: "id.token.x",
        idp: [token_endpoint: base <> "/idp/token", client_id: "idp-agent"]
      ]

      assert {:ok, session} = Client.connect(url, auth: auth)
      assert session.era == :legacy

      [initialize] = for %{"method" => "initialize"} = body <- mcp_bodies(requests()), do: body
      assert initialize["params"]["capabilities"]["extensions"] == %{@enterprise => %{}}
    end

    test "a workload's JWT grant, and the authorization code flow, declare none", ctx do
      {_base, url} = serve(ctx)

      assertion = fn _target -> {:ok, "workload.jwt.value"} end

      assert {:ok, _session} =
               Client.connect(url, auth: [grant: :jwt_bearer, assertion: assertion])

      for body <- mcp_bodies(requests()) do
        assert Map.keys(declared(body)) == [Sake.Tasks.extension()]
      end

      assert Sake.Client.Auth.extensions(Sake.Client.Auth.new(url, [], [])) == %{}
    end
  end

  test "the options are checked when the session is built" do
    url = "https://mcp.example.com/mcp"
    idp = [issuer: "https://idp", client_id: "a"]

    for {opts, message} <- [
          {[grant: :password], ~r/grant must be one of/},
          {[grant: :client_credentials, client_id: "a"], ~r/client_secret or :private_key/},
          {[grant: :client_credentials, client_secret: "s"], ~r/client_id/},
          {[grant: :client_credentials, client_id: "a", private_key: "nope"], ~r/PEM/},
          {[grant: :client_credentials, client_id: "a", private_key: {Keys.pem(), "HS256"}],
           ~r/algorithm/},
          {[grant: :jwt_bearer], ~r/assertion/},
          {[grant: :enterprise, id_token: "t", idp: [issuer: "https://idp"]], ~r/client_id/},
          {[grant: :enterprise, client_id: "a", idp: [issuer: "https://idp"]], ~r/id_token/},
          {[grant: :enterprise, client_id: "a", id_token: "t"], ~r/idp/},
          {[grant: :enterprise, client_id: "a", id_token: "t", saml_assertion: "s", idp: idp],
           ~r/not both/},
          {[grant: :enterprise, client_id: "a", saml_assertion: "s", idp: [token_endpoint: "x"]],
           ~r/saml_assertion needs idp: \[issuer/},
          {[
             grant: :client_credentials,
             client_id: "a",
             client_secret: "short",
             token_endpoint_auth_method: "client_secret_jwt"
           ], ~r/at least 32 bytes/},
          {[
             grant: :enterprise,
             client_id: "a",
             id_token: "t",
             idp: idp ++ [token_endpoint_auth_method: "client_secret_jwt"]
           ], ~r/idp: client_secret_jwt needs/}
        ] do
      assert_raise ArgumentError, message, fn -> Client.connect(url, auth: opts) end
    end
  end
end
