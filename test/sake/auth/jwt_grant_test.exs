defmodule Sake.Auth.JWTGrantTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.{Clients, Tokens}
  alias SakeTest.Keys

  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @idp "https://idp.example"
  @resource "http://www.example.com/mcp"

  # Restarts Sake with the AuthCase configuration and these trusted issuers.
  defp trust(issuers, overrides \\ []) do
    stop_supervised!(Sake)

    auth =
      Keyword.merge(
        [
          subject: SakeDev.Subject,
          issuer: "http://www.example.com",
          allow_insecure: true,
          servers: [SakeDev.Server],
          resources: ["/mcp", "/:org/mcp"],
          trusted_issuers: issuers
        ],
        overrides
      )

    start_supervised!(
      {Sake,
       auth: auth, secret_key_base: SakeTest.ModernClient.secret(), streams: false, tasks: false}
    )

    Sake.Auth.config()
  end

  defp post(params, headers \\ []) do
    conn =
      conn(:post, "/oauth/token", URI.encode_query(params))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Sake.Auth.Token.call(conn, Sake.Auth.Token.init([]))
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  defp jag_client(config, name \\ "Agent") do
    {:ok, client, nil} = Clients.create(config, %{name: name, grant_types: [@jwt_bearer]})
    client
  end

  defp id_jag(key, client, overrides \\ %{}, header \\ %{"typ" => "oauth-id-jag+jwt"}) do
    %{
      "iss" => @idp,
      "sub" => "00u123",
      "email" => "ana@example.com",
      "aud" => "http://www.example.com",
      "client_id" => client.id,
      "jti" => Keys.jti(),
      "iat" => Keys.now(),
      "exp" => Keys.now(300),
      "resource" => @resource,
      "scope" => "issues:read"
    }
    |> Map.merge(overrides)
    |> Map.reject(fn {_, v} -> is_nil(v) end)
    |> Keys.sign(key, header)
  end

  defp grant(client, assertion, extra \\ %{}),
    do:
      Map.merge(
        %{"grant_type" => @jwt_bearer, "assertion" => assertion, "client_id" => client.id},
        extra
      )

  defp assert_error(conn, status \\ 400, code) do
    assert conn.status == status, conn.resp_body
    assert body(conn)["error"] == code, conn.resp_body
  end

  describe "an enterprise ID-JAG" do
    setup do
      {key, jwk} = Keys.key(:ec, "idp-1")
      config = trust([[issuer: @idp, jwks: %{"keys" => [jwk]}, clients: :any]])
      %{config: config, key: key}
    end

    test "is exchanged for an access token for the person it names", %{config: config, key: key} do
      client = jag_client(config)
      conn = post(grant(client, id_jag(key, client)))

      assert conn.status == 200

      assert %{"access_token" => access, "token_type" => "Bearer", "scope" => "issues:read"} =
               b = body(conn)

      refute Map.has_key?(b, "refresh_token")

      {mod, state} = Sake.Auth.store(config)

      assert {:ok, %{subject_id: "u1", resource: @resource, client_id: id}} =
               mod.get_token(state, :access, Tokens.hash(access))

      assert id == client.id
    end

    test "a confidential client authenticates as usual", %{config: config, key: key} do
      {:ok, client, secret} =
        Clients.create(config, %{
          name: "Web agent",
          grant_types: [@jwt_bearer],
          confidential: true
        })

      auth = {"authorization", "Basic " <> Base.encode64(client.id <> ":" <> secret)}
      params = %{"grant_type" => @jwt_bearer, "assertion" => id_jag(key, client)}
      assert post(params, [auth]).status == 200

      conn = post(%{params | "assertion" => id_jag(key, client)})
      assert_error(conn, 401, "invalid_client")
    end

    test "scope and resource are narrowed, never widened", %{config: config, key: key} do
      client = jag_client(config)

      conn =
        post(
          grant(client, id_jag(key, client, %{"scope" => "issues:read issues:write"}), %{
            "scope" => "issues:write"
          })
        )

      assert conn.status == 200 and body(conn)["scope"] == "issues:write"

      conn = post(grant(client, id_jag(key, client), %{"scope" => "issues:write"}))
      assert_error(conn, "invalid_scope")

      conn = post(grant(client, id_jag(key, client), %{"scope" => "issues:read issues:write"}))
      assert conn.status == 200 and body(conn)["scope"] == "issues:read"

      conn = post(grant(client, id_jag(key, client, %{"scope" => nil})))
      assert conn.status == 200 and body(conn)["scope"] == "issues:read issues:write"

      conn =
        post(
          grant(client, id_jag(key, client), %{"resource" => "http://www.example.com/acme/mcp"})
        )

      assert_error(conn, "invalid_target")

      conn =
        post(grant(client, id_jag(key, client, %{"resource" => "https://other.example/mcp"})))

      assert_error(conn, "invalid_target")

      # Without a resource claim, the parameter decides.
      conn =
        post(
          grant(client, id_jag(key, client, %{"resource" => nil}), %{
            "resource" => "http://www.example.com/acme/mcp"
          })
        )

      assert conn.status == 200
    end

    test "every invalid grant is refused", %{config: config, key: key} do
      client = jag_client(config)
      other = jag_client(config, "Other")
      {stranger, _} = Keys.key(:ec, "idp-1")

      for {label, assertion} <- [
            other_key: id_jag(stranger, client),
            no_typ: id_jag(key, client, %{}, %{}),
            wrong_typ: id_jag(key, client, %{}, %{"typ" => "JWT"}),
            wrong_aud: id_jag(key, client, %{"aud" => "https://other-as.example"}),
            other_client: id_jag(key, other),
            expired: id_jag(key, client, %{"exp" => Keys.now(-60)}),
            future_iat: id_jag(key, client, %{"iat" => Keys.now(600)}),
            too_long: id_jag(key, client, %{"exp" => Keys.now(600)}),
            no_jti: id_jag(key, client, %{"jti" => nil}),
            no_client_id: id_jag(key, client, %{"client_id" => nil}),
            no_sub: id_jag(key, client, %{"sub" => nil}),
            untrusted: id_jag(key, client, %{"iss" => "https://evil.example"}),
            unknown_person: id_jag(key, client, %{"email" => "nobody@example.com"}),
            garbage: "a.b.c"
          ] do
        conn = post(grant(client, assertion))
        assert conn.status == 400, "#{label}: #{conn.resp_body}"
        assert body(conn)["error"] == "invalid_grant", "#{label}: #{conn.resp_body}"
      end

      assert_error(
        post(%{"grant_type" => @jwt_bearer, "client_id" => client.id}),
        "invalid_request"
      )
    end

    test "is accepted once", %{config: config, key: key} do
      client = jag_client(config)
      jwt = id_jag(key, client)
      assert post(grant(client, jwt)).status == 200
      conn = post(grant(client, jwt))
      assert_error(conn, "invalid_grant")
      assert body(conn)["error_description"] =~ "already used"
    end

    test "a client without the grant type is unauthorized_client", %{config: config, key: key} do
      client = public_client(config)
      assert_error(post(grant(client, id_jag(key, client))), "unauthorized_client")
    end

    test "the metadata advertises the grant and the ID-JAG profile", %{config: config} do
      body =
        conn(:get, "/.well-known/oauth-authorization-server")
        |> Sake.Auth.WellKnown.call([])
        |> Map.get(:resp_body)
        |> JSON.decode!()

      assert @jwt_bearer in body["grant_types_supported"]

      assert body["authorization_grant_profiles_supported"] == [
               "urn:ietf:params:oauth:grant-profile:id-jag"
             ]

      assert "private_key_jwt" in body["token_endpoint_auth_methods_supported"]
      assert body["token_endpoint_auth_signing_alg_values_supported"] == Sake.Auth.JWT.algs()
      assert config.trusted_issuers != []
    end
  end

  describe "trusted issuers" do
    test "only the clients named may present an issuer's grants", %{config: config} do
      {key, jwk} = Keys.key(:ec)
      allowed = jag_client(config, "Allowed")
      other = jag_client(config, "Other")
      config = trust([[issuer: @idp, jwks: %{"keys" => [jwk]}, clients: [allowed.id]]])
      assert config.trusted_issuers |> hd() |> Map.get(:clients) == [allowed.id]

      # The ETS store was restarted with Sake: register the two again.
      {mod, state} = Sake.Auth.store(config)
      :ok = mod.put_client(state, allowed)
      :ok = mod.put_client(state, other)

      assert post(grant(allowed, id_jag(key, allowed))).status == 200
      assert_error(post(grant(other, id_jag(key, other))), "unauthorized_client")
    end

    test "keys are found through the issuer's metadata" do
      {key, jwk} = Keys.key(:rsa, "r1")
      {base, docs} = Keys.serve(%{"/keys" => %{"keys" => [jwk]}})

      Keys.put(docs, "/.well-known/openid-configuration", %{
        "issuer" => base,
        "jwks_uri" => base <> "/keys"
      })

      config = trust([[issuer: base, clients: :any]])
      client = jag_client(config)

      assert post(
               grant(
                 client,
                 id_jag(key, client, %{"iss" => base}, %{
                   "typ" => "oauth-id-jag+jwt",
                   "kid" => "r1"
                 })
               )
             ).status == 200

      assert_received {:document_served, "/.well-known/openid-configuration"}
      assert_received {:document_served, "/keys"}
    end

    test "metadata that names another issuer is not used" do
      {key, jwk} = Keys.key(:ec)
      {base, docs} = Keys.serve(%{"/keys" => %{"keys" => [jwk]}})

      Keys.put(docs, "/.well-known/openid-configuration", %{
        "issuer" => "https://evil.example",
        "jwks_uri" => base <> "/keys"
      })

      config = trust([[issuer: base, clients: :any]])
      client = jag_client(config)
      conn = post(grant(client, id_jag(key, client, %{"iss" => base})))
      assert_error(conn, "invalid_grant")
      assert body(conn)["error_description"] =~ "keys could not be fetched"
    end

    test "a workload identity token needs no typ, client_id or jti" do
      {key, jwk} = Keys.key(:ec)

      config =
        trust([
          [
            issuer: "https://ci.example",
            profile: :workload,
            jwks: %{"keys" => [jwk]},
            audiences: ["https://mcp.example.com"],
            scopes: ["issues:read"],
            clients: :any
          ]
        ])

      client = jag_client(config)

      workload = fn overrides ->
        Keys.sign(
          Map.merge(
            %{
              "iss" => "https://ci.example",
              "sub" => "repo:acme/app:ref:refs/heads/main",
              "email" => "bo@example.com",
              "aud" => "https://mcp.example.com",
              "exp" => Keys.now(300)
            },
            overrides
          ),
          key
        )
      end

      conn = post(grant(client, workload.(%{}), %{"resource" => @resource}))
      assert conn.status == 200, conn.resp_body
      assert body(conn)["scope"] == "issues:read"

      {mod, state} = Sake.Auth.store(config)

      assert {:ok, %{subject_id: "u2"}} =
               mod.get_token(state, :access, Tokens.hash(body(conn)["access_token"]))

      # The issuer's scopes cap what it may ask for, and its audience is
      # the one configured, not this server's issuer.
      assert_error(
        post(
          grant(client, workload.(%{}), %{"resource" => @resource, "scope" => "issues:write"})
        ),
        "invalid_scope"
      )

      assert_error(
        post(
          grant(client, workload.(%{"aud" => "http://www.example.com"}), %{
            "resource" => @resource
          })
        ),
        "invalid_grant"
      )

      # A jti, when there is one, is single use.
      jwt = workload.(%{"jti" => "once"})
      assert post(grant(client, jwt, %{"resource" => @resource})).status == 200
      assert_error(post(grant(client, jwt, %{"resource" => @resource})), "invalid_grant")
    end

    test "a grant may stay valid for no longer than its issuer's max_lifetime" do
      {key, jwk} = Keys.key(:ec)

      workload = fn exp ->
        Keys.sign(
          %{
            "iss" => "https://ci.example",
            "sub" => "repo:acme/app:ref:refs/heads/main",
            "email" => "bo@example.com",
            "aud" => "http://www.example.com",
            "exp" => exp
          },
          key
        )
      end

      issuer = [
        issuer: "https://ci.example",
        profile: :workload,
        jwks: %{"keys" => [jwk]},
        clients: :any
      ]

      # A workload token may live an hour by default.
      config = trust([issuer])
      client = jag_client(config)

      assert post(grant(client, workload.(Keys.now(3_000)), %{"resource" => @resource})).status ==
               200

      assert_error(
        post(grant(client, workload.(Keys.now(7_200)), %{"resource" => @resource})),
        "invalid_grant"
      )

      config = trust([Keyword.put(issuer, :max_lifetime, 60)])
      client = jag_client(config)

      assert post(grant(client, workload.(Keys.now(60)), %{"resource" => @resource})).status ==
               200

      conn = post(grant(client, workload.(Keys.now(300)), %{"resource" => @resource}))
      assert_error(conn, "invalid_grant")
      assert body(conn)["error_description"] == "The grant is valid for too long"

      assert_raise ArgumentError, ~r/max_lifetime/, fn ->
        Sake.Auth.TrustedIssuer.new(issuer: @idp, clients: :any, max_lifetime: 0)
      end

      assert %{max_lifetime: 300} = Sake.Auth.TrustedIssuer.new(issuer: @idp, clients: :any)
    end

    test "without trusted issuers the grant is unsupported", %{config: config} do
      client = jag_client(config)
      assert_error(post(grant(client, "a.b.c")), "unsupported_grant_type")
    end

    test "the configuration is checked when Sake starts" do
      assert_raise ArgumentError, ~r/assertion_principal/, fn ->
        Sake.Auth.Config.new(
          subject: SakeTest.TenantSubject,
          issuer: "https://as.example",
          trusted_issuers: [[issuer: @idp, clients: :any]]
        )
      end

      for bad <- [
            [issuer: @idp],
            [issuer: @idp, clients: []],
            [issuer: @idp, clients: :any, profile: :saml],
            [clients: :any]
          ] do
        assert_raise ArgumentError, fn ->
          Sake.Auth.Config.new(
            subject: SakeDev.Subject,
            issuer: "https://as.example",
            trusted_issuers: [bad]
          )
        end
      end
    end
  end
end
