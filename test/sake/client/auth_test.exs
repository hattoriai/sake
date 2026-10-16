defmodule Sake.Client.AuthTest do
  use ExUnit.Case, async: true

  alias Sake.Client
  alias Sake.Client.Auth.{Grant, Headless}
  alias SakeTest.{FakeOAuth, HTTP}

  defmodule MemoryStore do
    @moduledoc false
    @behaviour Sake.Client.Auth.Store

    @impl true
    def fetch(agent, key) do
      case Agent.get(agent, &Map.fetch(&1, key)) do
        {:ok, value} -> {:ok, value}
        :error -> :error
      end
    end

    @impl true
    def put(agent, key, value), do: Agent.update(agent, &Map.put(&1, key, value))
  end

  @auth [authorize: &Headless.authorize/1]

  setup do
    %{state: FakeOAuth.state()}
  end

  defp serve(%{state: state}, opts \\ []) do
    base = HTTP.start({FakeOAuth, [test: self(), state: state] ++ opts})
    {base, base <> "/mcp"}
  end

  # Every request the fake server saw, in order, as `{method, path, params,
  # headers}`.
  defp requests(acc \\ []) do
    receive do
      {:fake_oauth, method, path, params, headers} ->
        requests([{method, path, params, headers} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp paths(requests), do: Enum.map(requests, fn {m, p, _, _} -> "#{m} #{p}" end)

  defp find(requests, method, path) do
    Enum.find_value(requests, fn
      {^method, ^path, params, headers} -> {params, Map.new(headers)}
      _ -> nil
    end)
  end

  defp count(requests, method, path),
    do: Enum.count(requests, &match?({^method, ^path, _, _}, &1))

  describe "without auth:" do
    test "a 401 comes back to the caller as a challenge", ctx do
      {_base, url} = serve(ctx, challenge_scope: "files:read")

      assert {:error, {:unauthorized, %Client.Challenge{scope: ["files:read"]} = challenge}} =
               Client.connect(url)

      assert challenge.resource_metadata =~ "/.well-known/oauth-protected-resource/mcp"
      assert paths(requests()) == ["POST /mcp"]
    end
  end

  describe "DPoP" do
    test "with a server that does not offer it, :auto sends no proofs", ctx do
      {_base, url} = serve(ctx)
      assert {:ok, session} = Client.connect(url, auth: @auth)
      assert session.auth.token["token_type"] == "Bearer"
      assert {_params, headers} = find(requests(), "POST", "/token")
      refute Map.has_key?(headers, "dpop")
    end

    test "dpop: true sends a proof anyway, and a bearer answer is used as one", ctx do
      {base, url} = serve(ctx)
      assert {:ok, session} = Client.connect(url, auth: [{:dpop, true} | @auth])
      requests = requests()

      assert {_params, %{"dpop" => proof}} = find(requests, "POST", "/token")
      assert {:ok, %{"typ" => "dpop+jwt", "jwk" => jwk}, claims} = Sake.Auth.JWT.peek(proof)
      assert %{"htm" => "POST", "htu" => htu} = claims
      assert htu == base <> "/token"
      refute Map.has_key?(claims, "ath")

      # The server bound nothing: the token goes as Bearer, with no proof.
      assert session.auth.token["token_type"] == "Bearer"
      assert {:ok, key} = Sake.Auth.JWT.private_key(session.auth.token["dpop_key"])
      assert Sake.Auth.JWT.public_jwk(key) == jwk

      {"POST", "/mcp", _params, sent} = requests |> Enum.reverse() |> List.keyfind("POST", 0)

      assert [{"authorization", "Bearer " <> _}] =
               for({k, _} = h <- sent, k in ~w(authorization dpop), do: h)
    end

    test "a resource that requires DPoP gets it, whatever the authorization server lists", ctx do
      {_base, url} =
        serve(ctx, resource_metadata: %{"dpop_bound_access_tokens_required" => true})

      assert {:ok, _session} = Client.connect(url, auth: @auth)
      assert {_params, %{"dpop" => _proof}} = find(requests(), "POST", "/token")
    end

    test "a resource that requires DPoP stops a client without it before anyone is asked", ctx do
      {_base, url} =
        serve(ctx, resource_metadata: %{"dpop_bound_access_tokens_required" => true})

      assert {:error, {:auth, {:dpop_required, :dpop_off}}} =
               Client.connect(url, auth: [{:dpop, false} | @auth])

      requests = requests()
      refute find(requests, "GET", "/authorize")
      refute find(requests, "POST", "/token")
      assert count(requests, "POST", "/mcp") == 1
    end

    test "a DPoP token in answer to no proof is refused", ctx do
      {_base, url} = serve(ctx, token_type: "DPoP")

      assert {:error, {:auth, {:token_type, "DPoP"}}} = Client.connect(url, auth: @auth)
    end
  end

  describe "the flow" do
    test "discovery, registration, PKCE, the token, then the request again with it", ctx do
      {base, url} = serve(ctx)

      assert {:ok, session} = Client.connect(url, auth: @auth)
      assert session.era == :modern
      requests = requests()

      assert paths(requests) == [
               "POST /mcp",
               "GET /.well-known/oauth-protected-resource/mcp",
               "GET /.well-known/oauth-authorization-server",
               "POST /register",
               "GET /authorize",
               "POST /token",
               "POST /mcp"
             ]

      {registration, _} = find(requests, "POST", "/register")

      assert registration["redirect_uris"] == ["http://127.0.0.1:33418/callback"]
      assert registration["application_type"] == "native"
      assert registration["token_endpoint_auth_method"] == "none"
      assert registration["grant_types"] == ["authorization_code", "refresh_token"]
      assert registration["client_name"] == "Sake"

      {authorize, _} = find(requests, "GET", "/authorize")

      assert %{
               "response_type" => "code",
               "client_id" => "registered-client",
               "code_challenge_method" => "S256",
               "redirect_uri" => "http://127.0.0.1:33418/callback",
               "resource" => resource
             } = authorize

      assert resource == base <> "/mcp"
      refute Map.has_key?(authorize, "scope")
      assert byte_size(authorize["state"]) >= 32

      {token, headers} = find(requests, "POST", "/token")
      assert Grant.challenge(token["code_verifier"]) == authorize["code_challenge"]
      assert token["resource"] == resource and token["client_id"] == "registered-client"
      refute Map.has_key?(token, "client_secret") or Map.has_key?(headers, "authorization")

      [_, {_, _, _, headers}] = Enum.filter(requests, &match?({"POST", "/mcp", _, _}, &1))
      assert {"authorization", "Bearer " <> _} = List.keyfind(headers, "authorization", 0)

      assert {:ok, result, _session} = Client.call_tool(session, "echo", %{})
      assert result.text == "echo"
      assert paths(requests()) == ["POST /mcp"]
    end

    test "the resource metadata falls back to the root well-known URI", ctx do
      {base, url} = serve(ctx, prm: :root, in_header: false)

      assert {:ok, _session} = Client.connect(url, auth: @auth)
      requests = requests()

      assert Enum.take(paths(requests), 3) == [
               "POST /mcp",
               "GET /.well-known/oauth-protected-resource/mcp",
               "GET /.well-known/oauth-protected-resource"
             ]

      # The resource identifier is sent exactly as the metadata publishes it.
      {authorize, _} = find(requests, "GET", "/authorize")
      assert authorize["resource"] == base
    end

    test "an issuer with a path: RFC 8414 and OpenID Connect URLs in order", ctx do
      {_base, url} =
        serve(ctx,
          issuer_path: "/tenant1",
          metadata_at: "/tenant1/.well-known/openid-configuration"
        )

      assert {:ok, _session} = Client.connect(url, auth: @auth)

      assert requests() |> paths() |> Enum.slice(2, 3) == [
               "GET /.well-known/oauth-authorization-server/tenant1",
               "GET /.well-known/openid-configuration/tenant1",
               "GET /tenant1/.well-known/openid-configuration"
             ]
    end

    test "a 2025-03-26 server without resource metadata is its own authorization server",
         ctx do
      {base, url} = serve(ctx, prm: :none, in_header: false)

      assert {:ok, _session} = Client.connect(url, auth: @auth)
      requests = requests()

      assert "GET /.well-known/oauth-authorization-server" in paths(requests)
      assert {%{"resource" => resource}, _} = find(requests, "GET", "/authorize")
      assert resource == base <> "/mcp"
    end

    test "the probe's token carries over to the legacy handshake", ctx do
      {_base, url} = serve(ctx, legacy: true)

      assert {:ok, session} = Client.connect(url, auth: @auth)
      assert session.era == :legacy and session.revision == "2025-06-18"
      requests = requests()
      assert count(requests, "GET", "/authorize") == 1
      assert {"POST", "/mcp", %{"method" => "initialize"}, _} = List.last(Enum.drop(requests, -1))
    end
  end

  describe "refusals" do
    test "metadata whose issuer is not the authorization server's", ctx do
      {_base, url} = serve(ctx, metadata: %{"issuer" => "https://attacker.example.com"})

      assert {:error, {:auth, {:issuer_mismatch, _, "https://attacker.example.com"}}} =
               Client.connect(url, auth: @auth)

      refute "GET /authorize" in paths(requests())
    end

    test "an authorization server that does not advertise S256", ctx do
      for methods <- [nil, ["plain"]] do
        {_base, url} = serve(ctx, metadata: %{"code_challenge_methods_supported" => methods})
        assert {:error, {:auth, :pkce_not_supported}} = Client.connect(url, auth: @auth)
        refute "POST /register" in paths(requests())
      end
    end

    test "resource metadata about another resource", ctx do
      {_base, url} =
        serve(ctx,
          prm: %{
            "resource" => "https://evil.example.com/mcp",
            "authorization_servers" => ["https://evil.example.com"]
          }
        )

      assert {:error, {:auth, {:resource_mismatch, "https://evil.example.com/mcp"}}} =
               Client.connect(url, auth: @auth)

      assert paths(requests()) == ["POST /mcp", "GET /.well-known/oauth-protected-resource/mcp"]
    end

    test "an authorization server endpoint over plain http to a real host", ctx do
      {_base, url} =
        serve(ctx, metadata: %{"authorization_endpoint" => "http://auth.example.com/authorize"})

      authorize = fn _url -> flunk("the person was sent to an insecure endpoint") end

      assert {:error, {:auth, {:insecure_url, "http://auth.example.com/authorize"}}} =
               Client.connect(url, auth: [authorize: authorize])
    end
  end

  describe "the authorization response" do
    for {name, opts} <- [
          {"a wrong iss", [iss: "https://evil.example.com"]},
          {"a trailing-slash iss", [iss: :trailing_slash]},
          {"a wrong iss from a server that does not advertise it",
           [
             iss: "https://evil.example.com",
             metadata: %{"authorization_response_iss_parameter_supported" => nil}
           ]}
        ] do
      test "is refused with #{name}, before the code reaches the token endpoint", ctx do
        {base, url} = serve(ctx, unquote(Macro.escape(opts)))

        assert {:error, {:auth, {:issuer_mismatch, ^base, iss}}} =
                 Client.connect(url, auth: @auth)

        assert iss != base
        refute "POST /token" in paths(requests())
      end
    end

    test "is refused without iss from a server that advertises it", ctx do
      {_base, url} =
        serve(ctx,
          iss: :omit,
          metadata: %{"authorization_response_iss_parameter_supported" => true}
        )

      assert {:error, {:auth, :missing_iss}} = Client.connect(url, auth: @auth)
      refute "POST /token" in paths(requests())
    end

    test "is accepted without iss from a server that does not advertise it", ctx do
      {_base, url} = serve(ctx, iss: :omit)
      assert {:ok, _session} = Client.connect(url, auth: @auth)
    end

    test "is refused when its state is not the request's", ctx do
      {_base, url} = serve(ctx)

      authorize = fn url ->
        {:ok, params} = Headless.authorize(url)
        {:ok, %{params | "state" => "forged"}}
      end

      assert {:error, {:auth, :state_mismatch}} =
               Client.connect(url, auth: [authorize: authorize])

      refute "POST /token" in paths(requests())
    end

    test "reports an error the authorization server sent", ctx do
      {_base, url} = serve(ctx)

      authorize = fn url ->
        {:ok, params} = Headless.authorize(url)
        {:ok, params |> Map.delete("code") |> Map.put("error", "access_denied")}
      end

      assert {:error, {:auth, {:denied, "access_denied", nil}}} =
               Client.connect(url, auth: [authorize: authorize])
    end
  end

  describe "scopes" do
    defp requested_scope(ctx, opts) do
      {_base, url} = serve(ctx, opts)
      assert {:ok, _session} = Client.connect(url, auth: @auth)
      {authorize, _} = find(requests(), "GET", "/authorize")
      authorize["scope"]
    end

    test "the challenge's scope first", ctx do
      assert requested_scope(ctx, challenge_scope: "files:read", scopes_supported: ["a", "b"]) ==
               "files:read"
    end

    test "else every scope the resource metadata supports", ctx do
      assert requested_scope(ctx, scopes_supported: ["a", "b", "c"]) == "a b c"
    end

    test "else none at all", ctx do
      assert requested_scope(ctx, []) == nil
    end

    test "offline_access only from an authorization server that lists it", ctx do
      assert requested_scope(ctx,
               challenge_scope: "a",
               metadata: %{"scopes_supported" => ["a", "offline_access"]}
             ) == "a offline_access"

      assert requested_scope(ctx, challenge_scope: "a", metadata: %{"scopes_supported" => ["a"]}) ==
               "a"

      assert requested_scope(ctx, metadata: %{"scopes_supported" => ["a", "offline_access"]}) ==
               nil
    end

    test "a 403 steps up to the union of the scopes so far and the challenged ones", ctx do
      {_base, url} = serve(ctx, challenge_scope: "a", call_scopes: ["a", "b"])

      assert {:ok, session} = Client.connect(url, auth: @auth)
      assert {:ok, %{text: "echo"}, session} = Client.call_tool(session, "echo", %{})

      scopes =
        for {"GET", "/authorize", params, _} <- requests(), do: params["scope"]

      assert scopes == ["a", "a b"]
      assert session.auth.token["scopes"] == ["a", "b"]
    end

    test "step-up gives up after two authorizations for one request", ctx do
      {_base, url} =
        serve(ctx, challenge_scope: "basic", call_scopes: ["admin"], grant: ["basic"])

      assert {:ok, session} = Client.connect(url, auth: @auth)

      assert {:error, {:insufficient_scope, %Client.Challenge{scope: ["admin"]}}, _session} =
               Client.call_tool(session, "echo", %{})

      assert count(requests(), "GET", "/authorize") == 3
    end

    test "no step-up for scopes the token already has", ctx do
      {_base, url} =
        serve(ctx, challenge_scope: "admin", call_scopes: ["admin"], deny_calls: true)

      assert {:ok, session} = Client.connect(url, auth: @auth)

      assert {:error, {:insufficient_scope, _}, _session} =
               Client.call_tool(session, "echo", %{})

      assert count(requests(), "GET", "/authorize") == 1
    end
  end

  describe "registration" do
    test "pre-registered credentials come first, with the method the server supports", ctx do
      for {supported, header?} <- [
            {["client_secret_basic"], true},
            {["client_secret_post"], false},
            {nil, true}
          ] do
        {_base, url} =
          serve(ctx, metadata: %{"token_endpoint_auth_methods_supported" => supported})

        auth = @auth ++ [client_id: "pre:registered", client_secret: "s3cret"]
        assert {:ok, _session} = Client.connect(url, auth: auth)
        requests = requests()

        refute "POST /register" in paths(requests)
        {token, headers} = find(requests, "POST", "/token")

        if header? do
          assert headers["authorization"] ==
                   "Basic " <> Base.encode64("pre%3Aregistered:s3cret")

          refute Map.has_key?(token, "client_secret")
        else
          assert token["client_id"] == "pre:registered" and token["client_secret"] == "s3cret"
          refute Map.has_key?(headers, "authorization")
        end
      end
    end

    test "pre-registered credentials are never offered to another authorization server", ctx do
      {_base, url} = serve(ctx)
      auth = @auth ++ [client_id: "c", issuer: "https://auth.example.com"]

      assert {:error, {:auth, {:client_issuer_mismatch, "https://auth.example.com", _}}} =
               Client.connect(url, auth: auth)

      refute "GET /authorize" in paths(requests())
    end

    test "a metadata document URL when the authorization server supports them", ctx do
      document = "https://app.example.com/client.json"

      {_base, url} =
        serve(ctx, metadata: %{"client_id_metadata_document_supported" => true})

      assert {:ok, _session} = Client.connect(url, auth: @auth ++ [client_metadata_url: document])
      requests = requests()
      refute "POST /register" in paths(requests)
      assert {%{"client_id" => ^document}, _} = find(requests, "GET", "/authorize")

      {_base, url} = serve(ctx)
      assert {:ok, _session} = Client.connect(url, auth: @auth ++ [client_metadata_url: document])
      assert {%{"client_id" => "registered-client"}, _} = find(requests(), "GET", "/authorize")
    end

    test "a metadata document URL must be https with a path" do
      assert_raise ArgumentError, fn ->
        Client.connect("http://127.0.0.1:1/mcp",
          auth: [client_metadata_url: "http://a.example/c"]
        )
      end
    end

    test "dynamic registration asks for a secret only from a server without public clients",
         ctx do
      {_base, url} =
        serve(ctx,
          metadata: %{"token_endpoint_auth_methods_supported" => ["client_secret_basic"]},
          registration: %{
            "client_secret" => "issued",
            "token_endpoint_auth_method" => "client_secret_basic"
          }
        )

      assert {:ok, _session} = Client.connect(url, auth: @auth)
      requests = requests()

      assert {%{"token_endpoint_auth_method" => "client_secret_basic"}, _} =
               find(requests, "POST", "/register")

      {_token, headers} = find(requests, "POST", "/token")
      assert headers["authorization"] == "Basic " <> Base.encode64("registered-client:issued")
    end

    test "a web application registers as one", ctx do
      {_base, url} = serve(ctx)
      auth = @auth ++ [redirect_uri: "https://app.example.com/callback"]

      assert {:ok, _session} = Client.connect(url, auth: auth)
      assert {%{"application_type" => "web"}, _} = find(requests(), "POST", "/register")
    end
  end

  describe "tokens" do
    test "an expired token is refreshed before the request", ctx do
      {_base, url} = serve(ctx, expires_in: 0)
      assert {:ok, session} = Client.connect(url, auth: @auth)
      _ = requests()

      assert {:ok, _result, session} = Client.call_tool(session, "echo", %{})
      assert paths(requests()) == ["POST /token", "POST /mcp"]
      assert session.auth.token["refresh_token"]
    end

    test "a 401 tries the refresh token before the whole flow", ctx do
      {_base, url} = serve(ctx)
      assert {:ok, session} = Client.connect(url, auth: @auth)
      _ = requests()

      Agent.update(ctx.state, &Map.put(&1, :tokens, %{}))
      assert {:ok, _result, _session} = Client.call_tool(session, "echo", %{})
      requests = requests()

      assert {%{"grant_type" => "refresh_token"}, _} = find(requests, "POST", "/token")
      refute "GET /authorize" in paths(requests)
    end

    test "a refresh token that fails gives way to the whole flow", ctx do
      {_base, url} = serve(ctx)
      assert {:ok, session} = Client.connect(url, auth: @auth)
      _ = requests()

      Agent.update(ctx.state, &%{&1 | tokens: %{}, refresh: %{}})
      assert {:ok, _result, _session} = Client.call_tool(session, "echo", %{})
      assert count(requests(), "GET", "/authorize") == 1
    end

    test "a store keeps the token and the registration across sessions", ctx do
      {:ok, store} = Agent.start_link(fn -> %{} end)
      {base, url} = serve(ctx)
      auth = @auth ++ [store: {MemoryStore, store}]

      assert {:ok, _session} = Client.connect(url, auth: auth)

      assert %{{:token, ^url} => %{"issuer" => ^base}, {:client, ^base} => _} =
               Agent.get(store, & &1)

      _ = requests()

      assert {:ok, _session} = Client.connect(url, auth: auth)
      assert paths(requests()) == ["POST /mcp"]

      # Without the token, the stored registration is used again.
      Agent.update(store, &Map.delete(&1, {:token, url}))
      assert {:ok, _session} = Client.connect(url, auth: auth)
      refute "POST /register" in paths(requests())
    end

    test "a registration with one authorization server is never used with another", ctx do
      {:ok, store} = Agent.start_link(fn -> %{} end)
      auth = @auth ++ [store: {MemoryStore, store}]
      {_base, url} = serve(ctx, registration: %{"client_id" => "client-1"})
      assert {:ok, _session} = Client.connect(url, auth: auth)
      _ = requests()

      {_base, url} =
        serve(%{state: FakeOAuth.state()}, registration: %{"client_id" => "client-2"})

      assert {:ok, _session} = Client.connect(url, auth: auth)
      requests = requests()
      assert "POST /register" in paths(requests)
      assert {%{"client_id" => "client-2"}, _} = find(requests, "GET", "/authorize")
    end
  end
end
