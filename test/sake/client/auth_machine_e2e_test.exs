defmodule Sake.Client.AuthMachineE2ETest.IdP do
  @moduledoc false
  # An enterprise identity provider: OpenID Connect metadata, its JWK Set,
  # and a token endpoint that exchanges an ID token (`id-token-<email>`)
  # for a real ID-JAG signed with its key, to the client the agent names.
  #
  # It takes SAML too (draft-ietf-oauth-identity-assertion-authz-grant
  # §4.5): a base64url-encoded assertion whose NameID is the person's
  # email is traded for a refresh token, which is then exchanged for the
  # ID-JAG. A client that authenticates with a client_secret_jwt
  # assertion has its HMAC checked against the agent's `:hmac_secret`.
  # Every exchange is sent to the agent's `:test` process as
  # `{:idp, subject_token_type, client_authentication}`.
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth.JWT

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, agent) do
    %{key: key, base: base} = Agent.get(agent, & &1)

    case {conn.method, conn.request_path} do
      {"GET", "/.well-known/openid-configuration"} ->
        json(conn, 200, %{
          "issuer" => base,
          "token_endpoint" => base <> "/token",
          "jwks_uri" => base <> "/jwks",
          "token_endpoint_auth_methods_supported" => Agent.get(agent, & &1.auth_methods)
        })

      {"GET", "/jwks"} ->
        json(conn, 200, %{"keys" => [Map.put(JWT.public_jwk(key), "kid", "idp-1")]})

      {"POST", "/token"} ->
        {:ok, body, conn} = read_body(conn)
        p = URI.decode_query(body)
        state = Agent.get(agent, & &1)
        send(state.test, {:idp, p["subject_token_type"], client_auth(p, state)})

        if client_auth(p, state) == :bad_assertion,
          do: json(conn, 401, %{"error" => "invalid_client"}),
          else: exchange(conn, p, agent)

      _other ->
        send_resp(conn, 404, "")
    end
  end

  defp exchange(
         conn,
         %{"subject_token_type" => "urn:ietf:params:oauth:token-type:saml2"} = p,
         agent
       ) do
    xml = Base.url_decode64!(p["subject_token"], padding: false)
    [_, email] = Regex.run(~r{<saml:NameID>([^<]+)</saml:NameID>}, xml)
    refresh = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    Agent.update(agent, &put_in(&1, [:refresh, refresh], email))

    json(conn, 200, %{
      "access_token" => "N_A",
      "refresh_token" => refresh,
      "issued_token_type" => "urn:ietf:params:oauth:token-type:refresh_token",
      "token_type" => "N_A",
      "expires_in" => 3600
    })
  end

  defp exchange(
         conn,
         %{"subject_token_type" => "urn:ietf:params:oauth:token-type:refresh_token"} = p,
         agent
       ) do
    case Agent.get(agent, &get_in(&1, [:refresh, p["subject_token"]])) do
      nil -> json(conn, 400, %{"error" => "invalid_grant"})
      email -> id_jag(conn, email, p, agent)
    end
  end

  defp exchange(conn, %{"subject_token" => "id-token-" <> email} = p, agent),
    do: id_jag(conn, email, p, agent)

  defp id_jag(conn, email, p, agent) do
    %{key: key, base: base, client_id: client_id} = Agent.get(agent, & &1)
    now = System.system_time(:second)

    jag =
      JWT.sign(
        %{
          "iss" => base,
          "sub" => "idp|" <> email,
          "email" => email,
          "aud" => p["audience"],
          "client_id" => client_id,
          "resource" => p["resource"],
          "scope" => "issues:read",
          "jti" => Base.encode16(:crypto.strong_rand_bytes(8)),
          "iat" => now,
          "exp" => now + 300
        },
        key,
        "ES256",
        %{"typ" => "oauth-id-jag+jwt", "kid" => "idp-1"}
      )

    json(conn, 200, %{
      "access_token" => jag,
      "issued_token_type" => "urn:ietf:params:oauth:token-type:id-jag",
      "token_type" => "N_A"
    })
  end

  # A client_secret_jwt assertion: HS256 with the secret, the client as
  # issuer and subject, this provider as the audience, unexpired.
  defp client_auth(%{"client_assertion" => jwt}, %{hmac_secret: secret, base: base}) do
    with [h, c, mac] <- String.split(jwt, "."),
         %{"alg" => "HS256"} <- JSON.decode!(Base.url_decode64!(h, padding: false)),
         true <-
           Base.url_decode64!(mac, padding: false) ==
             :crypto.mac(:hmac, :sha256, secret, h <> "." <> c),
         %{"iss" => id, "sub" => id, "aud" => ^base, "exp" => exp} <-
           JSON.decode!(Base.url_decode64!(c, padding: false)),
         true <- exp > System.system_time(:second) do
      :client_secret_jwt
    else
      _ -> :bad_assertion
    end
  end

  defp client_auth(%{"client_secret" => _}, _state), do: :client_secret_post
  defp client_auth(_params, _state), do: :other

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
  end
end

defmodule Sake.Client.AuthMachineE2ETest do
  # Sake.Client against Sake's own authorization server with no person at
  # all: a machine client with a secret or a key, an enterprise agent with
  # an ID token from a (fake, but really signing) identity provider, and
  # a workload with a platform JWT.
  use ExUnit.Case, async: false

  alias Sake.Auth.{Clients, JWT}
  alias Sake.Client
  alias SakeTest.{HTTP, Keys}

  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"

  setup do
    {idp_key, _} = Keys.key(:ec)
    test = self()

    {:ok, idp} =
      Agent.start_link(fn ->
        %{
          key: idp_key,
          base: nil,
          client_id: nil,
          test: test,
          refresh: %{},
          hmac_secret: nil,
          auth_methods: ["client_secret_post"]
        }
      end)

    idp_base = HTTP.start({__MODULE__.IdP, idp})
    Agent.update(idp, &%{&1 | base: idp_base})

    {workload_key, workload_jwk} = Keys.key(:ec)
    base = HTTP.start(SakeDev.Router)

    start_supervised!(
      {Sake,
       auth: [
         subject: SakeDev.Subject,
         issuer: base,
         allow_insecure: true,
         servers: [SakeDev.Server],
         resources: ["/mcp", "/acme/mcp", "/beta/mcp"],
         store: {Sake.Auth.Store.ETS, []},
         trusted_issuers: [
           [issuer: idp_base, clients: :any],
           [
             issuer: "https://ci.example",
             profile: :workload,
             jwks: %{"keys" => [workload_jwk]},
             clients: :any
           ]
         ]
       ],
       secret_key_base: SakeTest.ModernClient.secret(),
       streams: false,
       tasks: false}
    )

    %{
      base: base,
      url: base <> "/acme/mcp",
      config: Sake.Auth.config(),
      idp: idp,
      idp_base: idp_base,
      workload_key: workload_key
    }
  end

  test "a machine client with a secret, limited to its scopes", %{url: url, config: config} do
    {:ok, client, secret} =
      Clients.create(config, %{
        name: "Nightly",
        grant_types: ["client_credentials"],
        confidential: true,
        scopes: ["issues:read"]
      })

    auth = [grant: :client_credentials, client_id: client.id, client_secret: secret]
    assert {:ok, session} = Client.connect(url, auth: auth)
    assert session.auth.token["scopes"] == ["issues:read"]
    assert {:ok, %{text: "hi"}, session} = Client.call_tool(session, "echo", %{"text" => "hi"})

    # `slow` needs issues:write, which this client may not have: the
    # step-up asks for it, the authorization server grants issues:read
    # again, and the 403 stands.
    assert {:error, {:insufficient_scope, %Sake.Auth.Challenge{scope: ["issues:write"]}},
            _session} =
             Client.call_tool(session, "slow", %{"n" => 1})
  end

  test "a machine client with a key (private_key_jwt), on both eras", %{url: url, config: config} do
    pem = Keys.pem(:rsa)
    {:ok, key} = JWT.private_key(pem)

    {:ok, client, nil} =
      Clients.create(config, %{
        name: "Signer",
        grant_types: ["client_credentials"],
        jwks: %{"keys" => [JWT.public_jwk(key)]}
      })

    auth = [grant: :client_credentials, client_id: client.id, private_key: pem]
    assert {:ok, session} = Client.connect(url, auth: auth)

    # The token request carried a client assertion and a DPoP proof, two
    # keys for two purposes: the token is bound to the second.
    assert session.auth.token["token_type"] == "DPoP"

    assert {:ok, %{text: "counted to 1"}, _session} =
             Client.call_tool(session, "slow", %{"n" => 1})

    assert {:ok, session} = Client.connect(url, era: :legacy, auth: auth)
    assert {:ok, %{text: "x"}, _session} = Client.call_tool(session, "echo", %{"text" => "x"})

    # A token that expired is replaced by running the grant again.
    session = put_in(session.auth.token["expires_at"], System.system_time(:second))
    old = session.auth.token
    assert {:ok, _result, session} = Client.call_tool(session, "echo", %{"text" => "y"})
    assert session.auth.token["access_token"] != old["access_token"]
    assert session.auth.token["dpop_key"] == old["dpop_key"]
  end

  test "enterprise-managed: an ID token, an ID-JAG, then a token for the person", ctx do
    {:ok, client, nil} = Clients.create(ctx.config, %{name: "Agent", grant_types: [@jwt_bearer]})
    Agent.update(ctx.idp, &%{&1 | client_id: client.id})

    auth = [
      grant: :enterprise,
      client_id: client.id,
      id_token: "id-token-ana@example.com",
      idp: [issuer: ctx.idp_base, client_id: "agent-at-idp", client_secret: "idp-secret"]
    ]

    assert {:ok, session} = Client.connect(ctx.url, auth: auth)
    assert session.auth.token["scopes"] == ["issues:read"]
    assert session.auth.token["refresh_token"] == nil
    assert {:ok, %{text: "hi"}, _session} = Client.call_tool(session, "echo", %{"text" => "hi"})

    {module, state} = Sake.Auth.store(ctx.config)

    assert [%{kind: :access, client_id: id, resource: resource, jkt: jkt}] =
             module.tokens_for_subject(state, "u1")

    assert is_binary(jkt)

    assert id == client.id and resource == ctx.url

    # Someone the identity provider vouches for but who has no account
    # here gets nothing.
    auth = Keyword.put(auth, :id_token, "id-token-stranger@example.com")

    assert {:error, {:auth, {:token_failed, 400, %{"error" => "invalid_grant"}}}} =
             Client.connect(ctx.url, auth: auth)
  end

  test "enterprise-managed with SAML: the IdP's refresh token, then an ID-JAG", ctx do
    {:ok, client, nil} = Clients.create(ctx.config, %{name: "Agent", grant_types: [@jwt_bearer]})
    hmac_secret = Base.url_encode64(:crypto.strong_rand_bytes(32))

    # The provider takes the client's secret only as an HMAC key.
    Agent.update(
      ctx.idp,
      &%{&1 | client_id: client.id, hmac_secret: hmac_secret, auth_methods: ["client_secret_jwt"]}
    )

    saml = fn email ->
      Base.url_encode64(
        ~s(<saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion">) <>
          "<saml:Subject><saml:NameID>#{email}</saml:NameID></saml:Subject></saml:Assertion>",
        padding: false
      )
    end

    auth = [
      grant: :enterprise,
      client_id: client.id,
      saml_assertion: saml.("ana@example.com"),
      idp: [issuer: ctx.idp_base, client_id: "agent-at-idp", client_secret: hmac_secret]
    ]

    assert {:ok, session} = Client.connect(ctx.url, auth: auth)
    assert_received {:idp, "urn:ietf:params:oauth:token-type:saml2", :client_secret_jwt}
    assert_received {:idp, "urn:ietf:params:oauth:token-type:refresh_token", :client_secret_jwt}

    assert session.auth.token["scopes"] == ["issues:read"]
    assert {:ok, %{text: "hi"}, session} = Client.call_tool(session, "echo", %{"text" => "hi"})

    {module, state} = Sake.Auth.store(ctx.config)
    assert [%{client_id: id, resource: resource}] = module.tokens_for_subject(state, "u1")
    assert id == client.id and resource == ctx.url

    # The token expires: a new ID-JAG comes from the kept refresh token,
    # and the SAML assertion is not presented again.
    session = put_in(session.auth.token["expires_at"], System.system_time(:second))
    old = session.auth.token["access_token"]

    assert {:ok, %{text: "again"}, session} =
             Client.call_tool(session, "echo", %{"text" => "again"})

    assert session.auth.token["access_token"] != old
    assert_received {:idp, "urn:ietf:params:oauth:token-type:refresh_token", :client_secret_jwt}
    refute_received {:idp, "urn:ietf:params:oauth:token-type:saml2", _}

    # A wrong secret never gets past the provider.
    auth = put_in(auth[:idp][:client_secret], String.reverse(hmac_secret))

    assert {:error, {:auth, {:saml_exchange_failed, 401, %{"error" => "invalid_client"}}}} =
             Client.connect(ctx.url, auth: auth)
  end

  test "an ID-JAG issued to another client is refused", ctx do
    {:ok, client, nil} = Clients.create(ctx.config, %{name: "Agent", grant_types: [@jwt_bearer]})
    Agent.update(ctx.idp, &%{&1 | client_id: "someone-else"})

    auth = [
      grant: :enterprise,
      client_id: client.id,
      id_token: "id-token-ana@example.com",
      idp: [issuer: ctx.idp_base, client_id: "agent-at-idp"]
    ]

    assert {:error, {:auth, {:token_failed, 400, %{"error" => "invalid_grant"}}}} =
             Client.connect(ctx.url, auth: auth)
  end

  test "a workload presents its platform's JWT", ctx do
    {:ok, client, nil} = Clients.create(ctx.config, %{name: "CI", grant_types: [@jwt_bearer]})

    assertion = fn %{issuer: issuer} ->
      {:ok,
       Keys.sign(
         %{
           "iss" => "https://ci.example",
           "sub" => "repo:acme/app",
           "email" => "bo@example.com",
           "aud" => issuer,
           "exp" => Keys.now(300)
         },
         ctx.workload_key
       )}
    end

    auth = [grant: :jwt_bearer, client_id: client.id, assertion: assertion]
    assert {:ok, session} = Client.connect(ctx.url, auth: auth)
    assert {:ok, %{text: "w"}, _session} = Client.call_tool(session, "echo", %{"text" => "w"})
  end
end
