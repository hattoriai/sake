defmodule Sake.Client.AuthExternalE2ETest.Router do
  @moduledoc false
  # A host whose authorization server is someone else's: the well-known
  # metadata and two endpoints, one checking the server's JWT access
  # tokens and one asking its introspection endpoint. No Sake.Auth.
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/.well-known", to: Sake.Auth.WellKnown
  forward "/mcp", to: Sake.Plug, init_opts: [server: SakeDev.Server, auth: :fake]

  forward "/introspected/mcp",
    to: Sake.Plug,
    init_opts: [server: SakeDev.Server, auth: :introspected]

  match _, do: send_resp(conn, 404, "")
end

defmodule Sake.Client.AuthExternalE2ETest do
  # Sake.Client against an endpoint whose tokens come from an external
  # authorization server (a fake one, but really signing and binding):
  # it discovers that server from the endpoint's metadata, runs the
  # client credentials grant there, and calls the endpoint with the
  # token, on both eras.
  use ExUnit.Case, async: false

  alias Sake.Auth.JWT
  alias Sake.Client
  alias SakeTest.{FakeOAuth, HTTP, Keys}

  setup tags do
    {:ok, key} = JWT.private_key(Keys.pem())
    state = FakeOAuth.state()

    issuer =
      HTTP.start(
        {FakeOAuth,
         test: self(),
         state: state,
         jwt: key,
         dpop: Map.get(tags, :dpop, true),
         grant: tags[:grant] || ["issues:read", "issues:write"],
         introspection: {"mcp-resource", "resource-secret"},
         metadata: %{"token_endpoint_auth_methods_supported" => ["client_secret_basic"]}}
      )

    base = HTTP.start(__MODULE__.Router)

    start_supervised!(
      {Sake,
       secret_key_base: SakeTest.ModernClient.secret(),
       streams: false,
       tasks: false,
       external_auth: [
         fake: [
           issuer: issuer,
           verify: :jwt,
           servers: [SakeDev.Server],
           resources: ["/mcp"],
           allow_insecure: true
         ],
         introspected: [
           issuer: issuer,
           verify:
             {:introspection,
              endpoint: issuer <> "/introspect",
              client_id: "mcp-resource",
              client_secret: "resource-secret"},
           servers: [SakeDev.Server],
           resources: ["/introspected/mcp"],
           allow_insecure: true
         ]
       ]}
    )

    %{
      base: base,
      issuer: issuer,
      auth: [grant: :client_credentials, client_id: "svc", client_secret: "pw"]
    }
  end

  test "client credentials at the external server, a DPoP-bound JWT, calls on both eras", ctx do
    assert {:ok, session} = Client.connect(ctx.base <> "/mcp", auth: ctx.auth)

    # The client found the authorization server through the endpoint's
    # metadata, and asked it for a token for this endpoint.
    assert session.auth.token["token_type"] == "DPoP"
    assert_received {:fake_oauth, "POST", "/token", params, _headers}
    assert params["grant_type"] == "client_credentials"
    assert params["resource"] == ctx.base <> "/mcp"

    {:ok, _header, claims} = JWT.peek(session.auth.token["access_token"])
    assert claims["iss"] == ctx.issuer and is_binary(claims["cnf"]["jkt"])

    assert {:ok, %{text: "hi"}, session} = Client.call_tool(session, "echo", %{"text" => "hi"})

    assert {:ok, %{text: "counted to 1"}, _session} =
             Client.call_tool(session, "slow", %{"n" => 1})

    assert {:ok, session} = Client.connect(ctx.base <> "/mcp", era: :legacy, auth: ctx.auth)
    assert {:ok, %{text: "x"}, _session} = Client.call_tool(session, "echo", %{"text" => "x"})
  end

  @tag grant: ["issues:read"]
  test "a scope the external server will not grant: the step-up fails and the 403 stands",
       ctx do
    assert {:ok, session} = Client.connect(ctx.base <> "/mcp", auth: ctx.auth)
    assert {:ok, %{text: "hi"}, session} = Client.call_tool(session, "echo", %{"text" => "hi"})

    assert {:error, {:insufficient_scope, %Sake.Auth.Challenge{scope: ["issues:write"]}},
            _session} =
             Client.call_tool(session, "slow", %{"n" => 1})
  end

  @tag dpop: false
  test "a bearer token from a server that does not offer DPoP", ctx do
    assert {:ok, session} = Client.connect(ctx.base <> "/mcp", auth: ctx.auth)
    assert session.auth.token["token_type"] == "Bearer"
    assert {:ok, %{text: "b"}, _session} = Client.call_tool(session, "echo", %{"text" => "b"})
  end

  test "an endpoint that introspects the token", ctx do
    url = ctx.base <> "/introspected/mcp"
    assert {:ok, session} = Client.connect(url, auth: ctx.auth)
    assert {:ok, %{text: "i"}, session} = Client.call_tool(session, "echo", %{"text" => "i"})
    assert_received {:fake_oauth, "POST", "/introspect", %{"token" => token}, _headers}
    assert token == session.auth.token["access_token"]

    # The answer is cached: the next call does not ask again.
    assert {:ok, %{text: "j"}, _session} = Client.call_tool(session, "echo", %{"text" => "j"})
    refute_received {:fake_oauth, "POST", "/introspect", _, _}

    assert {:ok, session} = Client.connect(url, era: :legacy, auth: ctx.auth)
    assert {:ok, %{text: "k"}, _session} = Client.call_tool(session, "echo", %{"text" => "k"})
  end

  test "a token from the external server is not one for another endpoint", ctx do
    assert {:ok, session} = Client.connect(ctx.base <> "/mcp", auth: ctx.auth)
    token = session.auth.token["access_token"]

    # The same token at the other endpoint: its audience is /mcp.
    response =
      Req.post!(ctx.base <> "/introspected/mcp",
        json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}},
        headers: [
          {"authorization", "Bearer " <> token},
          {"accept", "application/json, text/event-stream"}
        ],
        retry: false
      )

    assert response.status == 401
  end
end
