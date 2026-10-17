defmodule Sake.Auth.ExternalTest.Tokens do
  @moduledoc false
  # An in-app provider's tokens, as ExOauth2Provider or Boruta would find
  # them in the database: `verify_token/2` answers with atom keys and a
  # DateTime expiry, and loads the person along with the token.
  @behaviour Sake.Auth.External

  @impl true
  def verify_token("person-token", _conn),
    do:
      {:ok,
       %{
         sub: "u1",
         client_id: "app",
         scope: ["issues:read"],
         aud: "http://www.example.com/mcp",
         exp: DateTime.add(DateTime.utc_now(), 600)
       }, %{id: "u1", name: "Ana"}}

  def verify_token("claims-only", _conn),
    do: {:ok, %{sub: "u2", scope: "issues:read issues:write", aud: "http://www.example.com/mcp"}}

  def verify_token("no-audience", _conn), do: {:ok, %{sub: "u3", scope: "issues:read"}}

  def verify_token("expired", _conn),
    do:
      {:ok,
       %{sub: "u1", aud: "http://www.example.com/mcp", exp: System.system_time(:second) - 10}}

  def verify_token("bound", _conn),
    do:
      {:ok,
       %{
         sub: "u1",
         aud: "http://www.example.com/mcp",
         cnf: %{jkt: :persistent_term.get({__MODULE__, :jkt})}
       }}

  # Bound to a client certificate (RFC 8705), which Sake cannot check.
  def verify_token("certificate-bound", _conn),
    do: {:ok, %{sub: "u1", aud: "http://www.example.com/mcp", cnf: %{"x5t#S256": "dGh1bWI"}}}

  def verify_token(_token, _conn), do: :error
end

defmodule Sake.Auth.ExternalTest do
  # An endpoint whose tokens come from an authorization server Sake does
  # not run: JWT access tokens checked against the issuer's keys, token
  # introspection, and the host's own callback.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.{DPoP, External, JWT, TokenRecord}
  alias SakeTest.{FakeOAuth, HTTP, Keys, ModernClient}

  @issuer "https://idp.example.com"
  @resource "http://www.example.com/mcp"
  @prm "http://www.example.com/.well-known/oauth-protected-resource/mcp"

  defp start_sake(external, extra \\ []) do
    start_supervised!(
      {Sake,
       [
         external_auth: external,
         secret_key_base: ModernClient.secret(),
         streams: false,
         tasks: false
       ] ++ extra}
    )

    :ok
  end

  defp jwt_config(jwk, extra \\ []),
    do:
      [issuer: @issuer, verify: :jwt, jwks: %{"keys" => [jwk]}, servers: [SakeDev.Server]] ++
        extra

  defp jwt(key, claims \\ %{}, header \\ %{}) do
    %{
      "iss" => @issuer,
      "sub" => "user-1",
      "aud" => @resource,
      "client_id" => "app",
      "scope" => "issues:read",
      "iat" => Keys.now(),
      "exp" => Keys.now(300)
    }
    |> Map.merge(claims)
    |> Map.reject(fn {_, v} -> is_nil(v) end)
    |> Keys.sign(key, Map.merge(%{"typ" => "at+jwt", "kid" => "k1"}, header))
  end

  defp call(auth, token, method \\ "tools/list", params \\ %{}, headers \\ []) do
    ModernClient.post(ModernClient.opts(auth: auth), method, params,
      headers: [{"authorization", "Bearer " <> token} | headers]
    )
  end

  defp tool_names(conn), do: Enum.map(ModernClient.json(conn)["result"]["tools"], & &1["name"])

  # Every refusal is a telemetry event with its reason.
  defp watch_refusals do
    id = "external-refusals-#{System.unique_integer()}"
    test = self()

    :telemetry.attach(
      id,
      [:sake, :auth, :external, :refused],
      fn _event, _measurements, meta, _ -> send(test, {:refused, meta.name, meta.reason}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "JWT access tokens (RFC 9068)" do
    setup do
      {key, jwk} = Keys.key(:ec, "k1")
      start_sake(idp: jwt_config(jwk))
      watch_refusals()
      %{key: key, jwk: jwk}
    end

    test "a valid token: its scopes, its subject, the claims as the principal", %{key: key} do
      conn = call(:idp, jwt(key))
      assert conn.status == 200
      assert "issue_board" in tool_names(conn)
      assert ModernClient.json(conn)["result"]["cacheScope"] == "private"

      assert %TokenRecord{
               kind: :access,
               issuer: @issuer,
               subject_id: "user-1",
               client_id: "app",
               scopes: ["issues:read"],
               resource: @resource,
               jkt: nil,
               claims: %{"sub" => "user-1"}
             } = conn.assigns.sake_token

      assert conn.assigns.sake_scope["sub"] == "user-1"
      assert %DateTime{} = conn.assigns.sake_token.expires_at

      # `scp` and lists work as well as a `scope` string; `azp` names the
      # client when `client_id` does not.
      conn =
        call(
          :idp,
          jwt(key, %{
            "scope" => nil,
            "scp" => ["issues:read", "issues:write"],
            "client_id" => nil,
            "azp" => "spa"
          })
        )

      assert conn.status == 200
      assert conn.assigns.sake_token.scopes == ["issues:read", "issues:write"]
      assert conn.assigns.sake_token.client_id == "spa"
    end

    test "a token whose sub is its client is a machine client's", %{key: key} do
      conn = call(:idp, jwt(key, %{"sub" => "svc", "client_id" => "svc"}))
      assert conn.status == 200
      assert %{subject_id: nil, client_id: "svc"} = conn.assigns.sake_token

      conn = call(:idp, jwt(key, %{"sub" => nil, "client_id" => "svc"}))
      assert conn.status == 200
      assert %{subject_id: nil, client_id: "svc"} = conn.assigns.sake_token
    end

    test "missing scopes are a step-up challenge naming this endpoint's metadata", %{key: key} do
      conn = call(:idp, jwt(key), "tools/call", %{"name" => "slow", "arguments" => %{"n" => 1}})
      assert conn.status == 403

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer error="insufficient_scope", scope="issues:write", resource_metadata="#{@prm}")
             ]

      conn =
        call(:idp, jwt(key, %{"scope" => "issues:read issues:write"}), "tools/call", %{
          "name" => "slow",
          "arguments" => %{"n" => 1}
        })

      assert conn.status == 200
    end

    test "no token: a 401 that points at the metadata", %{key: _key} do
      conn = ModernClient.post(ModernClient.opts(auth: :idp), "tools/list")
      assert conn.status == 401

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Bearer resource_metadata="#{@prm}", scope="issues:read issues:write"),
               ~s(DPoP resource_metadata="#{@prm}", scope="issues:read issues:write", algs="RS256 PS256 ES256 ES384")
             ]
    end

    test "refused: another issuer, another audience, expired, not yet valid, no exp", %{key: key} do
      for {claims, reason} <- [
            {%{"iss" => "https://evil.example"}, :invalid_issuer},
            {%{"iss" => @issuer <> "/"}, :invalid_issuer},
            {%{"iss" => nil}, :invalid_issuer},
            {%{"aud" => "http://www.example.com/other/mcp"}, :invalid_audience},
            {%{"aud" => ["https://api.example.com", "app"]}, :invalid_audience},
            {%{"aud" => nil}, :invalid_audience},
            {%{"exp" => Keys.now(-60)}, :expired},
            {%{"nbf" => Keys.now(600)}, :not_yet_valid},
            {%{"exp" => nil}, {:missing_claim, "exp"}}
          ] do
        conn = call(:idp, jwt(key, claims))
        assert conn.status == 401, inspect(claims)
        assert_received {:refused, :idp, ^reason}
      end

      # An audience among several is enough.
      assert call(:idp, jwt(key, %{"aud" => ["https://api.example.com", @resource]})).status ==
               200
    end

    test "refused: another key's signature, an unknown kid, an HMAC alg, the wrong typ", %{
      key: key,
      jwk: jwk
    } do
      {other, _} = Keys.key(:ec, "k1")
      assert call(:idp, jwt(other)).status == 401
      assert_received {:refused, :idp, :bad_signature}

      assert call(:idp, jwt(key, %{}, %{"kid" => "k2"})).status == 401
      assert_received {:refused, :idp, :no_key}

      # Algorithm confusion: an HMAC "signature" keyed with the public
      # key, which a verifier that let the token pick its algorithm would
      # accept.
      [_header, claims, _signature] = String.split(jwt(key), ".")

      header =
        Base.url_encode64(JSON.encode!(%{"alg" => "HS256", "typ" => "at+jwt", "kid" => "k1"}),
          padding: false
        )

      mac =
        :hmac
        |> :crypto.mac(:sha256, JSON.encode!(jwk), header <> "." <> claims)
        |> Base.url_encode64(padding: false)

      assert call(:idp, header <> "." <> claims <> "." <> mac).status == 401
      assert_received {:refused, :idp, :unsupported_alg}

      none =
        Base.url_encode64(JSON.encode!(%{"alg" => "none", "typ" => "at+jwt"}), padding: false)

      assert call(:idp, none <> "." <> claims <> ".").status == 401

      # An ID token, or any other JWT the issuer signs, is not an access
      # token.
      assert call(:idp, jwt(key, %{}, %{"typ" => "JWT"})).status == 401
      assert_received {:refused, :idp, :invalid_typ}
      assert call(:idp, "not-a-jwt").status == 401
      assert_received {:refused, :idp, :malformed}
    end

    test "refused: a binding Sake cannot check (cnf.x5t#S256), bearer or DPoP", %{key: key} do
      thumbprint = Base.url_encode64(:crypto.hash(:sha256, "a certificate"), padding: false)
      token = jwt(key, %{"cnf" => %{"x5t#S256" => thumbprint}})

      assert call(:idp, token).status == 401
      assert_received {:refused, :idp, :unsupported_confirmation}

      {proof_key, proof_jwk} = Keys.key()

      conn =
        ModernClient.post(ModernClient.opts(auth: :idp), "tools/list", %{},
          headers: [
            {"authorization", "DPoP " <> token},
            {"dpop", DPoP.proof(proof_key, "POST", @resource, access_token: token)}
          ]
        )

      assert conn.status == 401

      assert [~s(DPoP error="invalid_token") <> _, "Bearer " <> _] =
               get_resp_header(conn, "www-authenticate")

      assert_received {:refused, :idp, :unsupported_confirmation}

      # Next to a jkt too, and a cnf that is no JSON object, or whose jkt
      # is no string.
      for cnf <- [
            %{"jkt" => JWT.thumbprint(proof_jwk), "x5t#S256" => thumbprint},
            "bound",
            %{"jkt" => 1}
          ] do
        assert call(:idp, jwt(key, %{"cnf" => cnf})).status == 401, inspect(cnf)
        assert_received {:refused, :idp, :unsupported_confirmation}
      end

      # A token with no cnf is taken as before, and one bound with jkt
      # alone with a proof of its key.
      assert call(:idp, jwt(key)).status == 200
      token = jwt(key, %{"cnf" => %{"jkt" => JWT.thumbprint(proof_jwk)}})

      conn =
        ModernClient.post(ModernClient.opts(auth: :idp), "tools/list", %{},
          headers: [
            {"authorization", "DPoP " <> token},
            {"dpop", DPoP.proof(proof_key, "POST", @resource, access_token: token)}
          ]
        )

      assert conn.status == 200
    end

    test "with the DPoP scheme, an invalid token is a DPoP invalid_token", %{key: key} do
      {proof_key, _} = Keys.key()
      token = jwt(key, %{"exp" => Keys.now(-60)})

      conn =
        ModernClient.post(ModernClient.opts(auth: :idp), "tools/list", %{},
          headers: [
            {"authorization", "DPoP " <> token},
            {"dpop", DPoP.proof(proof_key, "POST", @resource, access_token: token)}
          ]
        )

      assert conn.status == 401

      assert [~s(DPoP error="invalid_token") <> _, "Bearer " <> _] =
               get_resp_header(conn, "www-authenticate")
    end

    test "the legacy era is protected the same way", %{key: key} do
      initialize = fn headers ->
        conn(
          :post,
          "/mcp",
          JSON.encode!(
            Sake.JSONRPC.request(0, "initialize", %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "legacy", "version" => "0"}
            })
          )
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> then(&Enum.reduce(headers, &1, fn {k, v}, c -> put_req_header(c, k, v) end))
        |> Sake.Plug.call(ModernClient.opts(auth: :idp))
      end

      assert initialize.([]).status == 401
      token = jwt(key)
      conn = initialize.([{"authorization", "Bearer " <> token}])
      assert conn.status == 200
      [session] = get_resp_header(conn, "mcp-session-id")

      call = fn token, name ->
        conn(
          :post,
          "/mcp",
          JSON.encode!(
            Sake.JSONRPC.request(1, "tools/call", %{"name" => name, "arguments" => %{"n" => 1}})
          )
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> put_req_header("mcp-session-id", session)
        |> put_req_header("authorization", "Bearer " <> token)
        |> Sake.Plug.call(ModernClient.opts(auth: :idp))
      end

      assert call.(token, "slow").status == 403
      assert call.(jwt(key, %{"scope" => "issues:write"}), "slow").status == 200
      assert call.(jwt(key, %{"aud" => "https://api.example.com"}), "slow").status == 401
    end
  end

  describe "JWT options" do
    test "typ: \"JWT\" for an identity provider that issues plain JWTs; audiences:" do
      {key, jwk} = Keys.key(:rsa, "k1")

      start_sake(
        plain:
          jwt_config(jwk,
            typ: "JWT",
            audiences: ["https://api.example.com"],
            resources: ["/plain/mcp"]
          ),
        any: jwt_config(jwk, typ: :any, audiences: :any, resources: ["/any/mcp"])
      )

      # The configured audience replaces the endpoint's URL.
      plain = jwt(key, %{"aud" => "https://api.example.com"}, %{"typ" => "JWT"})
      assert call(:plain, plain).status == 200
      assert call(:plain, jwt(key, %{}, %{"typ" => "JWT"})).status == 401
      assert call(:plain, jwt(key, %{"aud" => "https://api.example.com"})).status == 401

      # `audiences: :any` takes a token with no audience at all.
      assert call(:any, jwt(key, %{"aud" => nil}, %{"typ" => "JWT"})).status == 200
    end
  end

  describe "keys from the issuer's metadata" do
    test "found through OpenID Connect discovery; an unknown kid refetches the set once" do
      {key1, jwk1} = Keys.key(:ec, "k1")
      {key2, jwk2} = Keys.key(:ec, "k2")
      {base, docs} = Keys.serve(%{"/keys" => %{"keys" => [jwk1]}})

      Keys.put(docs, "/.well-known/openid-configuration", %{
        "issuer" => base,
        "jwks_uri" => base <> "/keys"
      })

      start_sake(
        idp: [issuer: base, verify: :jwt, servers: [SakeDev.Server], allow_insecure: true]
      )

      assert call(:idp, jwt(key1, %{"iss" => base})).status == 200
      assert_received {:document_served, "/.well-known/openid-configuration"}
      assert_received {:document_served, "/keys"}

      # The issuer rotates a key in. The set was fetched just now, so an
      # unknown kid does not refetch it yet: nobody can make the server
      # fetch on every request by inventing key IDs.
      Keys.put(docs, "/keys", %{"keys" => [jwk1, jwk2]})
      token2 = jwt(key2, %{"iss" => base}, %{"kid" => "k2"})
      assert call(:idp, token2).status == 401
      refute_received {:document_served, _}

      # A minute later it does, once, and the new key works.
      {:ok, {keys, fetched_at}} = Sake.Auth.CIMD.Cache.get({:jwks, base <> "/keys"})
      Sake.Auth.CIMD.Cache.put({:jwks, base <> "/keys"}, {keys, fetched_at - 120}, 3_600)

      assert call(:idp, token2).status == 200
      assert_received {:document_served, "/keys"}
      assert call(:idp, token2).status == 200
      refute_received {:document_served, _}

      # Another unknown kid right after is refused without a fetch.
      {key3, _} = Keys.key(:ec, "k3")
      assert call(:idp, jwt(key3, %{"iss" => base}, %{"kid" => "k3"})).status == 401
      refute_received {:document_served, _}
    end
  end

  describe "DPoP-bound tokens from the external server (cnf.jkt)" do
    setup tags do
      {key, jwk} = Keys.key(:ec, "k1")
      start_sake(idp: jwt_config(jwk, dpop: tags[:dpop] || true))
      {client_key, client_jwk} = Keys.key()
      token = jwt(key, %{"cnf" => %{"jkt" => JWT.thumbprint(client_jwk)}})
      %{token: token, client_key: client_key, key: key}
    end

    defp dpop_call(token, proof) do
      ModernClient.post(ModernClient.opts(auth: :idp), "tools/list", %{},
        headers: [
          {"authorization", "DPoP " <> token} | if(proof, do: [{"dpop", proof}], else: [])
        ]
      )
    end

    test "taken with a proof of the bound key, and only with it", ctx do
      proof = DPoP.proof(ctx.client_key, "POST", @resource, access_token: ctx.token)
      conn = dpop_call(ctx.token, proof)
      assert conn.status == 200
      assert conn.assigns.sake_token.jkt == JWT.thumbprint(JWT.public_jwk(ctx.client_key))

      # As a bearer token it is refused: a stolen one would work without
      # the key otherwise.
      conn = call(:idp, ctx.token)
      assert conn.status == 401

      assert [
               ~s(DPoP error="invalid_token", error_description="The access token is DPoP-bound) <>
                 _,
               _
             ] =
               get_resp_header(conn, "www-authenticate")

      # No proof, a replayed one, another key's.
      assert dpop_call(ctx.token, nil).status == 401
      assert dpop_call(ctx.token, proof).status == 401
      {other, _} = Keys.key()

      assert dpop_call(ctx.token, DPoP.proof(other, "POST", @resource, access_token: ctx.token)).status ==
               401
    end

    @tag dpop: [nonce: true]
    test "with nonces, the resource's own", ctx do
      conn =
        dpop_call(
          ctx.token,
          DPoP.proof(ctx.client_key, "POST", @resource, access_token: ctx.token)
        )

      assert conn.status == 401
      assert [nonce] = get_resp_header(conn, "dpop-nonce")

      proof = DPoP.proof(ctx.client_key, "POST", @resource, access_token: ctx.token, nonce: nonce)
      assert dpop_call(ctx.token, proof).status == 200
    end

    @tag dpop: [required: true]
    test "dpop: [required: true] refuses an unbound token, and the metadata says so", ctx do
      conn =
        conn(:get, "/.well-known/oauth-protected-resource/mcp") |> Sake.Auth.WellKnown.call([])

      assert JSON.decode!(conn.resp_body)["dpop_bound_access_tokens_required"] == true

      proof = DPoP.proof(ctx.client_key, "POST", @resource, access_token: ctx.token)
      assert dpop_call(ctx.token, proof).status == 200
      assert call(:idp, jwt(ctx.key)).status == 401
    end
  end

  describe "token introspection (RFC 7662)" do
    setup tags do
      state = FakeOAuth.state()

      base =
        HTTP.start(
          {FakeOAuth,
           test: self(),
           state: state,
           introspection: {"mcp-resource", "s3cret"},
           jwt_claims: tags[:jwt_claims]}
        )

      start_sake(
        intro: [
          issuer: base,
          verify:
            {:introspection,
             [
               endpoint: base <> "/introspect",
               client_id: "mcp-resource",
               client_secret: tags[:secret] || "s3cret"
             ] ++
               if(tags[:cache], do: [cache: tags[:cache]], else: [])},
          servers: [SakeDev.Server],
          allow_insecure: true
        ]
      )

      watch_refusals()
      %{base: base, state: state}
    end

    # A token the fake authorization server issued, for this resource.
    defp issued(ctx, scope \\ "issues:read", resource \\ @resource) do
      conn =
        Req.post!(ctx.base <> "/token",
          form: [
            grant_type: "client_credentials",
            client_id: "svc",
            scope: scope,
            resource: resource
          ]
        )

      assert_received {:fake_oauth, "POST", "/token", _, _}
      conn.body["access_token"]
    end

    test "an active token is taken, and its answer cached by a digest", ctx do
      token = issued(ctx)
      conn = call(:intro, token)
      assert conn.status == 200

      assert %{subject_id: nil, client_id: "svc", scopes: ["issues:read"]} =
               conn.assigns.sake_token

      assert_received {:fake_oauth, "POST", "/introspect", %{"token" => ^token}, headers}
      assert {"authorization", "Basic " <> _} = List.keyfind(headers, "authorization", 0)

      assert call(:intro, token).status == 200
      refute_received {:fake_oauth, "POST", "/introspect", _, _}

      # The cache never holds the token itself, and no entry outlives the
      # token's own expiry.
      entries = :ets.tab2list(Sake.Auth.External.Cache)
      assert [{{:intro, digest}, _claims, expires_at}] = entries
      assert digest == :crypto.hash(:sha256, token)
      refute inspect(entries) =~ token
      assert expires_at <= System.system_time(:second) + 60

      # Revoked at the authorization server, it still works here until
      # the entry expires: the trade-off of the cache.
      Agent.update(ctx.state, &put_in(&1, [:revoked, token], true))
      assert call(:intro, token).status == 200
    end

    @tag cache: 0
    test "cache: 0 asks every time, so a revocation is seen at once", ctx do
      token = issued(ctx)
      assert call(:intro, token).status == 200
      Agent.update(ctx.state, &put_in(&1, [:revoked, token], true))
      assert call(:intro, token).status == 401
      assert_received {:refused, :intro, :inactive}
      assert :ets.tab2list(Sake.Auth.External.Cache) == []
    end

    test "inactive, unknown, for another resource: refused, and not cached", ctx do
      assert call(:intro, "made-up").status == 401
      assert_received {:refused, :intro, :inactive}

      token = issued(ctx, "issues:read", "http://www.example.com/other/mcp")
      assert call(:intro, token).status == 401
      assert_received {:refused, :intro, :invalid_audience}

      assert call(:intro, "made-up").status == 401
      assert_received {:fake_oauth, "POST", "/introspect", %{"token" => "made-up"}, _}
      assert_received {:fake_oauth, "POST", "/introspect", %{"token" => "made-up"}, _}
    end

    @tag jwt_claims: %{"cnf" => %{"x5t#S256" => "dGh1bWI"}}
    test "an active token bound to a client certificate is refused", ctx do
      assert call(:intro, issued(ctx)).status == 401
      assert_received {:refused, :intro, :unsupported_confirmation}
    end

    @tag secret: "wrong"
    test "the resource's own credentials are refused: no token is taken", ctx do
      assert call(:intro, issued(ctx)).status == 401
      assert_received {:refused, :intro, :introspection_refused}
    end
  end

  describe "the host's callback" do
    setup do
      start_sake(
        app: [
          issuer: "https://app.example.com",
          verify: Sake.Auth.ExternalTest.Tokens,
          servers: [SakeDev.Server]
        ]
      )

      watch_refusals()
    end

    test "a module's verify_token/2: atom keys, a DateTime expiry, its own principal" do
      conn = call(:app, "person-token")
      assert conn.status == 200
      assert conn.assigns.sake_scope == %{id: "u1", name: "Ana"}

      assert %{
               subject_id: "u1",
               client_id: "app",
               scopes: ["issues:read"],
               issuer: "https://app.example.com"
             } =
               conn.assigns.sake_token

      conn =
        call(:app, "claims-only", "tools/call", %{"name" => "slow", "arguments" => %{"n" => 1}})

      assert conn.status == 200
      assert conn.assigns.sake_scope["sub"] == "u2"
    end

    test ":error, an expiry past, no audience: refused" do
      assert call(:app, "nope").status == 401
      assert_received {:refused, :app, :refused_by_callback}
      assert call(:app, "expired").status == 401
      assert_received {:refused, :app, :expired}

      # The callback must name the audience unless the host says any will do.
      assert call(:app, "no-audience").status == 401
      assert_received {:refused, :app, :invalid_audience}
    end

    test "a bound token from the callback needs its key" do
      {client_key, client_jwk} = Keys.key()
      :persistent_term.put({Sake.Auth.ExternalTest.Tokens, :jkt}, JWT.thumbprint(client_jwk))
      assert call(:app, "bound").status == 401

      conn =
        ModernClient.post(ModernClient.opts(auth: :app), "tools/list", %{},
          headers: [
            {"authorization", "DPoP bound"},
            {"dpop", DPoP.proof(client_key, "POST", @resource, access_token: "bound")}
          ]
        )

      assert conn.status == 200
    end

    test "a token the callback says is bound to a client certificate is refused" do
      assert call(:app, "certificate-bound").status == 401
      assert_received {:refused, :app, :unsupported_confirmation}

      {client_key, _client_jwk} = Keys.key()

      conn =
        ModernClient.post(ModernClient.opts(auth: :app), "tools/list", %{},
          headers: [
            {"authorization", "DPoP certificate-bound"},
            {"dpop", DPoP.proof(client_key, "POST", @resource, access_token: "certificate-bound")}
          ]
        )

      assert conn.status == 401
      assert_received {:refused, :app, :unsupported_confirmation}
    end
  end

  describe "the callback as a function, with principal: and audiences: :any" do
    test "the principal function maps the claims; :error refuses" do
      verify = fn
        "t-" <> sub, %Plug.Conn{} -> {:ok, %{"sub" => sub, "scope" => "issues:read"}}
        _token, _conn -> :error
      end

      principal = fn
        %{"sub" => "ghost"} -> :error
        %{"sub" => sub} -> {:ok, {:user, sub}}
      end

      start_sake(
        app: [
          issuer: "https://app.example.com",
          verify: verify,
          principal: principal,
          audiences: :any
        ]
      )

      watch_refusals()
      conn = call(:app, "t-ana")
      assert conn.status == 200
      assert conn.assigns.sake_scope == {:user, "ana"}

      assert call(:app, "t-ghost").status == 401
      assert_received {:refused, :app, :no_principal}
    end
  end

  describe "the protected resource metadata and the capabilities" do
    test "next to Sake.Auth: each endpoint names its own authorization server" do
      {_key, jwk} = Keys.key(:ec, "k1")

      start_sake(
        [
          idp:
            jwt_config(jwk,
              resources: ["/partners/mcp", "/:org/partners/mcp"],
              resource_name: "Partners",
              extensions: [:client_credentials]
            )
        ],
        auth: [
          subject: SakeDev.Subject,
          issuer: "http://www.example.com",
          allow_insecure: true,
          servers: [SakeDev.Server]
        ]
      )

      prm = fn path ->
        conn =
          conn(:get, "/.well-known/oauth-protected-resource" <> path)
          |> Sake.Auth.WellKnown.call([])

        JSON.decode!(conn.resp_body)
      end

      assert %{
               "resource" => "http://www.example.com/acme/partners/mcp",
               "authorization_servers" => [@issuer],
               "scopes_supported" => ["issues:read", "issues:write"],
               "bearer_methods_supported" => ["header"],
               "resource_name" => "Partners",
               "dpop_signing_alg_values_supported" => ["RS256", "PS256", "ES256", "ES384"]
             } = prm.("/acme/partners/mcp")

      assert %{"authorization_servers" => ["http://www.example.com"]} = prm.("/mcp")
      assert %{"authorization_servers" => ["http://www.example.com"]} = prm.("/partners")
    end

    test "url: names the origin clients reach, behind a proxy that sends another host" do
      {key, jwk} = Keys.key(:ec, "k1")
      start_sake(idp: jwt_config(jwk, url: "https://MCP.example/"))

      # The request's own origin is not the one named: Sake warns, once.
      ExUnit.CaptureLog.capture_log(fn ->
        conn =
          conn(:get, "/.well-known/oauth-protected-resource/mcp")
          |> Map.put(:host, "app.internal")
          |> Sake.Auth.WellKnown.call([])

        assert JSON.decode!(conn.resp_body)["resource"] == "https://mcp.example/mcp"
      end)

      proxied = fn token ->
        ModernClient.post(ModernClient.opts(auth: :idp), "tools/list", %{},
          headers: [{"authorization", "Bearer " <> token}],
          host: "app.internal"
        )
      end

      assert proxied.(jwt(key, %{"aud" => "https://mcp.example/mcp"})).status == 200
      assert proxied.(jwt(key, %{"aud" => "http://app.internal/mcp"})).status == 401

      for {url, message} <- [
            {"https://mcp.example/mcp", ~r/url: is an origin/},
            {"http://mcp.example", ~r/url: must be an https URL/}
          ] do
        assert_raise ArgumentError, message, fn -> External.new(:x, jwt_config(jwk, url: url)) end
      end
    end

    test "external servers only: Sake.Auth is not needed, and has no metadata" do
      {key, jwk} = Keys.key(:ec, "k1")
      start_sake(idp: jwt_config(jwk, extensions: [:client_credentials, :enterprise]))

      conn =
        conn(:get, "/.well-known/oauth-protected-resource/any/path")
        |> Sake.Auth.WellKnown.call([])

      assert JSON.decode!(conn.resp_body)["authorization_servers"] == [@issuer]

      conn = conn(:get, "/.well-known/oauth-authorization-server") |> Sake.Auth.WellKnown.call([])
      assert conn.status == 404

      conn = call(:idp, jwt(key), "server/discover")
      assert conn.status == 200

      extensions = ModernClient.json(conn)["result"]["capabilities"]["extensions"]
      assert Map.has_key?(extensions, Sake.Protocol.auth_extension(:client_credentials))
      assert Map.has_key?(extensions, Sake.Protocol.auth_extension(:enterprise))
    end

    test "by default an external endpoint declares no authorization extension" do
      {key, jwk} = Keys.key(:ec, "k1")
      start_sake(idp: jwt_config(jwk))
      conn = call(:idp, jwt(key), "server/discover")
      extensions = ModernClient.json(conn)["result"]["capabilities"]["extensions"]
      refute Map.has_key?(extensions, Sake.Protocol.auth_extension(:client_credentials))
      refute Map.has_key?(extensions, Sake.Protocol.auth_extension(:enterprise))
    end

    test "without any authorization server, there is no protected resource" do
      start_sake([])

      conn =
        conn(:get, "/.well-known/oauth-protected-resource/mcp") |> Sake.Auth.WellKnown.call([])

      assert conn.status == 404
    end
  end

  describe "tasks and request states are the issuer's" do
    test "the same sub from two issuers, or from Sake.Auth, is two principals" do
      ctx = fn token -> %Sake.Context{token: token} end
      own = %TokenRecord{subject_id: "u1", client_id: "c"}
      a = %{own | issuer: "https://a.example"}
      b = %{own | issuer: "https://b.example"}

      principals = Enum.map([own, a, b], &Sake.Tasks.principal(ctx.(&1)))
      assert Enum.uniq(principals) == principals

      assert Sake.Tasks.principal(ctx.(a)) ==
               Sake.Tasks.principal(ctx.(%{a | claims: %{"x" => 1}}))

      machine = %TokenRecord{subject_id: nil, client_id: "svc", issuer: "https://a.example"}
      assert "issuer:" <> _ = Sake.Tasks.principal(ctx.(machine))
      assert Sake.Tasks.principal(ctx.(machine)) =~ ":client:svc"

      secret = ModernClient.secret()

      state =
        Sake.Server.RequestState.sign(
          %{ctx.(a) | secret: secret, method: "tools/call"},
          "t",
          %{},
          %{}
        )

      assert {:ok, _} =
               Sake.Server.RequestState.verify(
                 %{ctx.(a) | secret: secret, method: "tools/call"},
                 "t",
                 %{},
                 state
               )

      assert :error =
               Sake.Server.RequestState.verify(
                 %{ctx.(b) | secret: secret, method: "tools/call"},
                 "t",
                 %{},
                 state
               )

      assert :error =
               Sake.Server.RequestState.verify(
                 %{ctx.(own) | secret: secret, method: "tools/call"},
                 "t",
                 %{},
                 state
               )
    end
  end

  describe "Sake.Test" do
    test "the in-memory client's token stands for any issuer's; through a plug, send one" do
      {key, jwk} = Keys.key(:ec, "k1")
      start_sake(idp: jwt_config(jwk))

      client = Sake.Test.connect(SakeDev.Server, scopes: ["issues:read"])
      assert {:error, {:insufficient_scope, _}} = Sake.Test.call_tool(client, "slow", %{"n" => 1})

      plug = {Sake.Plug, server: SakeDev.Server, auth: :idp}

      assert_raise ArgumentError, ~r/external authorization server/, fn ->
        Sake.Test.connect(SakeDev.Server, plug: plug, scopes: ["issues:read"], subject: "u1")
      end

      client =
        Sake.Test.connect(SakeDev.Server,
          plug: plug,
          headers: [{"authorization", "Bearer " <> jwt(key, %{"scope" => "issues:write"})}]
        )

      assert {:ok, %{text: "counted to 1"}} = Sake.Test.call_tool(client, "slow", %{"n" => 1})
    end
  end

  describe "configuration, checked at start" do
    test "mistakes are told at once" do
      {_key, jwk} = Keys.key(:ec, "k1")

      for {opts, message} <- [
            {[verify: :jwt], ~r/needs an issuer/},
            {[issuer: "http://idp.example", verify: :jwt], ~r/must be an https URL/},
            {[issuer: @issuer], ~r/verify: is :jwt/},
            {[issuer: @issuer, verify: :magic], ~r/has no verify_token\/2/},
            {[issuer: @issuer, verify: "x"], ~r/verify: is :jwt/},
            {[issuer: @issuer, verify: :jwt, audiences: []], ~r/audiences:/},
            {[issuer: @issuer, verify: :jwt, typ: nil], ~r/typ:/},
            {[issuer: @issuer, verify: :jwt, extensions: [:dpop]], ~r/extensions:/},
            {[issuer: @issuer, verify: :jwt, principal: :nope], ~r/principal:/},
            {[issuer: @issuer, verify: {:introspection, endpoint: @issuer <> "/i"}],
             ~r/client_id: and client_secret:/},
            {[
               issuer: @issuer,
               verify:
                 {:introspection, endpoint: "http://x/i", client_id: "a", client_secret: "b"}
             ], ~r/must be an https URL/},
            {[issuer: @issuer, verify: :jwt], ~r/needs resources:/}
          ] do
        assert_raise ArgumentError, message, fn ->
          External.new_all([x: opts, y: jwt_config(jwk, resources: ["/y/mcp"])], nil)
        end
      end

      assert_raise KeyError, fn -> External.new(:x, jwt_config(jwk, unknown: 1)) end

      assert_raise ArgumentError, ~r/names are atoms/, fn ->
        External.new_all([{true, []}], nil)
      end

      assert %{a: _} = External.new_all([a: jwt_config(jwk)], nil)
      assert %{dpop: false} = External.new(:x, jwt_config(jwk, dpop: false))

      assert_raise ArgumentError, ~r/is true, false or the name/, fn ->
        Sake.Plug.init(server: SakeDev.Server, auth: [issuer: @issuer])
      end
    end

    test "an endpoint naming no configuration says so" do
      start_sake([])

      assert_raise RuntimeError, ~r/names no external_auth/, fn ->
        call(:nowhere, "x")
      end
    end
  end
end
