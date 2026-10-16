defmodule Sake.Client.AuthMachineE2ETest.IdP do
  @moduledoc false
  # An enterprise identity provider: OpenID Connect metadata, its JWK Set,
  # and a token endpoint that exchanges an ID token (`id-token-<email>`)
  # for a real ID-JAG signed with its key, to the client the agent names.
  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth.JWT

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, agent) do
    %{key: key, base: base, client_id: client_id} = Agent.get(agent, & &1)

    case {conn.method, conn.request_path} do
      {"GET", "/.well-known/openid-configuration"} ->
        json(conn, %{
          "issuer" => base,
          "token_endpoint" => base <> "/token",
          "jwks_uri" => base <> "/jwks"
        })

      {"GET", "/jwks"} ->
        json(conn, %{"keys" => [Map.put(JWT.public_jwk(key), "kid", "idp-1")]})

      {"POST", "/token"} ->
        {:ok, body, conn} = read_body(conn)
        p = URI.decode_query(body)
        "id-token-" <> email = p["subject_token"]
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

        json(conn, %{
          "access_token" => jag,
          "issued_token_type" => "urn:ietf:params:oauth:token-type:id-jag",
          "token_type" => "N_A"
        })

      _other ->
        send_resp(conn, 404, "")
    end
  end

  defp json(conn, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(body))
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
    {:ok, idp} = Agent.start_link(fn -> %{key: idp_key, base: nil, client_id: nil} end)
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
    assert {:error, {:insufficient_scope, %Client.Challenge{scope: ["issues:write"]}}, _session} =
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
