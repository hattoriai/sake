defmodule Sake.Auth.ClientCredentialsTest.Refusing do
  @moduledoc false
  # The development subject, refusing one machine client by name.
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
  def client_principal(%{name: "Refused"}), do: :error
  def client_principal(client), do: SakeDev.Subject.client_principal(client)
end

defmodule Sake.Auth.ClientCredentialsTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.CIMD.Cache
  alias Sake.Auth.{Clients, JWT, Tokens}
  alias SakeTest.{Keys, ModernClient}

  @resource "http://www.example.com/mcp"
  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

  defp post(params, headers \\ []) do
    conn =
      conn(:post, "/oauth/token", URI.encode_query(params))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Sake.Auth.Token.call(conn, Sake.Auth.Token.init([]))
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  defp basic(id, secret),
    do:
      {"authorization",
       "Basic " <> Base.encode64(URI.encode_www_form(id) <> ":" <> URI.encode_www_form(secret))}

  defp secret_client(config, attrs \\ %{}) do
    {:ok, client, secret} =
      Clients.create(
        config,
        Map.merge(
          %{name: "Nightly", grant_types: ["client_credentials"], confidential: true},
          attrs
        )
      )

    {client, secret}
  end

  defp key_client(config, attrs \\ %{}) do
    {key, jwk} = Keys.key(:ec, "k1")

    {:ok, client, nil} =
      Clients.create(
        config,
        Map.merge(
          %{name: "Signer", grant_types: ["client_credentials"], jwks: %{"keys" => [jwk]}},
          attrs
        )
      )

    {client, key}
  end

  defp assertion(client, key, overrides \\ %{}) do
    %{
      "iss" => client.id,
      "sub" => client.id,
      "aud" => "http://www.example.com",
      "exp" => Keys.now(60),
      "iat" => Keys.now(),
      "jti" => Keys.jti()
    }
    |> Map.merge(overrides)
    |> Map.reject(fn {_, v} -> is_nil(v) end)
    |> Keys.sign(key, %{"kid" => "k1"})
  end

  defp grant(extra \\ %{}),
    do: Map.merge(%{"grant_type" => "client_credentials", "resource" => @resource}, extra)

  defp assert_invalid_client(conn) do
    assert conn.status == 401
    assert body(conn)["error"] == "invalid_client"
    assert [~s(Basic realm="sake")] = get_resp_header(conn, "www-authenticate")
  end

  describe "with a secret" do
    test "client_secret_basic issues an access token alone, with no subject", %{config: config} do
      {client, secret} = secret_client(config)
      conn = post(grant(), [basic(client.id, secret)])

      assert conn.status == 200
      assert ["no-store"] = get_resp_header(conn, "cache-control")

      assert %{"access_token" => access, "token_type" => "Bearer", "expires_in" => 3600} =
               body = body(conn)

      refute Map.has_key?(body, "refresh_token")
      assert body["scope"] == "issues:read issues:write"

      {mod, state} = Sake.Auth.store(config)

      assert {:ok, %{subject_id: nil, client_id: id, resource: @resource}} =
               mod.get_token(state, :access, Tokens.hash(access))

      assert id == client.id
    end

    test "client_secret_post, and the scopes the client may have", %{config: config} do
      {client, secret} = secret_client(config, %{scopes: ["issues:read"]})
      params = %{"client_id" => client.id, "client_secret" => secret}

      conn = post(grant(params))
      assert conn.status == 200 and body(conn)["scope"] == "issues:read"

      # Asking for more is narrowed to what it may have; asking only for
      # what it may not is refused.
      conn = post(grant(Map.put(params, "scope", "issues:read issues:write")))
      assert conn.status == 200 and body(conn)["scope"] == "issues:read"

      conn = post(grant(Map.put(params, "scope", "issues:write")))
      assert conn.status == 400 and body(conn)["error"] == "invalid_scope"

      conn = post(grant(Map.put(params, "scope", "unknown")))
      assert conn.status == 400 and body(conn)["error"] == "invalid_scope"
    end

    test "a wrong or missing secret is invalid_client", %{config: config} do
      {client, _secret} = secret_client(config)
      assert_invalid_client(post(grant(), [basic(client.id, "wrong")]))
      assert_invalid_client(post(grant(%{"client_id" => client.id})))
      assert_invalid_client(post(grant(), [basic("unknown", "x")]))
    end

    test "the resource must be one this server serves", %{config: config} do
      {client, secret} = secret_client(config)

      conn =
        post(grant(%{"resource" => "https://elsewhere.example/mcp"}), [basic(client.id, secret)])

      assert conn.status == 400 and body(conn)["error"] == "invalid_target"

      # Two endpoints are served, so a request without a resource is ambiguous.
      conn = post(%{"grant_type" => "client_credentials"}, [basic(client.id, secret)])
      assert conn.status == 400 and body(conn)["error"] == "invalid_target"

      conn =
        post(grant(%{"resource" => "http://www.example.com/acme/mcp"}), [basic(client.id, secret)])

      assert conn.status == 200
    end
  end

  describe "refusals" do
    test "a public client may not use the grant, even if it lists it", %{config: config} do
      client = public_client(config)
      {mod, state} = Sake.Auth.store(config)
      :ok = mod.put_client(state, %{client | grant_types: ["client_credentials"]})

      conn = post(grant(%{"client_id" => client.id}))
      assert conn.status == 400 and body(conn)["error"] == "unauthorized_client"
    end

    test "a client without the grant type is unauthorized_client", %{config: config} do
      {:ok, client, secret} =
        Clients.create(config, %{
          name: "Web",
          redirect_uris: ["https://app.example/cb"],
          confidential: true
        })

      conn = post(grant(), [basic(client.id, secret)])
      assert conn.status == 400 and body(conn)["error"] == "unauthorized_client"
    end

    @tag auth: [subject: Sake.Auth.ClientCredentialsTest.Refusing]
    test "the subject module refuses a client", %{config: config} do
      {client, secret} = secret_client(config, %{name: "Refused"})
      conn = post(grant(), [basic(client.id, secret)])
      assert conn.status == 400 and body(conn)["error"] == "unauthorized_client"
    end

    @tag auth: [subject: SakeTest.TenantSubject]
    test "without client_principal/1 the grant is not offered", %{config: config} do
      assert {:error,
              %{grant_types: "client_credentials needs the subject module's client_principal/1"}} =
               Clients.create(config, %{
                 name: "Nightly",
                 grant_types: ["client_credentials"],
                 confidential: true
               })

      conn = post(grant(%{"client_id" => "x", "client_secret" => "y"}))
      assert conn.status == 400 and body(conn)["error"] == "unsupported_grant_type"
    end
  end

  describe "private_key_jwt" do
    test "a signed assertion authenticates the client", %{config: config} do
      {client, key} = key_client(config)
      assert client.token_endpoint_auth_method == "private_key_jwt"

      conn =
        post(
          grant(%{
            "client_assertion_type" => @assertion_type,
            "client_assertion" => assertion(client, key)
          })
        )

      assert conn.status == 200
      assert %{"access_token" => _} = body(conn)

      # The token endpoint's URL is an acceptable audience too, and the
      # client_id parameter may be sent when it names the same client.
      conn =
        post(
          grant(%{
            "client_id" => client.id,
            "client_assertion_type" => @assertion_type,
            "client_assertion" =>
              assertion(client, key, %{"aud" => ["http://www.example.com/oauth/token"]})
          })
        )

      assert conn.status == 200
    end

    test "every bad assertion is invalid_client", %{config: config} do
      {client, key} = key_client(config)
      {other, other_key} = key_client(config, %{name: "Other"})
      {stranger, _} = Keys.key(:ec, "k1")

      with_assertion = fn jwt, extra ->
        post(
          grant(
            Map.merge(
              %{"client_assertion_type" => @assertion_type, "client_assertion" => jwt},
              extra
            )
          )
        )
      end

      # signed with another key, or another client's
      assert_invalid_client(with_assertion.(assertion(client, stranger), %{}))
      assert_invalid_client(with_assertion.(assertion(client, other_key), %{}))
      # claims
      assert_invalid_client(
        with_assertion.(assertion(client, key, %{"aud" => "https://other.example"}), %{})
      )

      assert_invalid_client(with_assertion.(assertion(client, key, %{"iss" => other.id}), %{}))

      assert_invalid_client(
        with_assertion.(assertion(client, key, %{"exp" => Keys.now(-120)}), %{})
      )

      assert_invalid_client(
        with_assertion.(assertion(client, key, %{"exp" => Keys.now(7200)}), %{})
      )

      assert_invalid_client(with_assertion.(assertion(client, key, %{"jti" => nil}), %{}))
      assert_invalid_client(with_assertion.(assertion(client, key, %{"exp" => nil}), %{}))
      # the client_id parameter names another client
      assert_invalid_client(with_assertion.(assertion(client, key), %{"client_id" => other.id}))
      # an unknown assertion type, or none at all
      assert_invalid_client(
        post(
          grant(%{
            "client_assertion_type" => "urn:other",
            "client_assertion" => assertion(client, key)
          })
        )
      )

      assert_invalid_client(post(grant(%{"client_assertion_type" => @assertion_type})))
      assert_invalid_client(with_assertion.("not.a.jwt", %{}))
      # a client registered for private_key_jwt is never let in by its id alone
      assert_invalid_client(post(grant(%{"client_id" => client.id})))
      # two methods in one request
      jwt = assertion(client, key)

      assert_invalid_client(
        post(grant(%{"client_assertion_type" => @assertion_type, "client_assertion" => jwt}), [
          basic(client.id, "x")
        ])
      )
    end

    test "an assertion may stay valid for five minutes at most", %{config: config} do
      {client, key} = key_client(config)

      with_exp = fn exp ->
        post(
          grant(%{
            "client_assertion_type" => @assertion_type,
            "client_assertion" => assertion(client, key, %{"exp" => exp})
          })
        )
      end

      assert with_exp.(Keys.now(300)).status == 200
      assert_invalid_client(with_exp.(Keys.now(600)))
    end

    @tag auth: [max_assertion_lifetime: 3_600]
    test "max_assertion_lifetime: lets a client sign for longer", %{config: config} do
      {client, key} = key_client(config)

      conn =
        post(
          grant(%{
            "client_assertion_type" => @assertion_type,
            "client_assertion" => assertion(client, key, %{"exp" => Keys.now(1_800)})
          })
        )

      assert conn.status == 200

      assert_raise ArgumentError, ~r/max_assertion_lifetime/, fn ->
        Sake.Auth.Config.new(
          subject: SakeDev.Subject,
          issuer: "http://www.example.com",
          allow_insecure: true,
          max_assertion_lifetime: 0
        )
      end
    end

    test "an assertion is accepted once", %{config: config} do
      {client, key} = key_client(config)
      jwt = assertion(client, key)
      params = grant(%{"client_assertion_type" => @assertion_type, "client_assertion" => jwt})

      assert post(params).status == 200
      assert_invalid_client(post(params))
    end

    test "a secret client cannot authenticate with an assertion", %{config: config} do
      {client, _secret} = secret_client(config)
      {key, _jwk} = Keys.key(:ec, "k1")

      assert_invalid_client(
        post(
          grant(%{
            "client_assertion_type" => @assertion_type,
            "client_assertion" => assertion(client, key)
          })
        )
      )
    end

    # client_secret_jwt is not offered here: the secret is stored hashed,
    # so there is nothing to check an HMAC with. An HMAC'd assertion is
    # refused whatever it is keyed with: the client's secret, or the bytes
    # of a key client's public key (algorithm confusion).
    test "an HMAC assertion is invalid_client, keyed with a secret or a public key", %{
      config: config
    } do
      hs256 = fn client, secret ->
        claims = %{
          "iss" => client.id,
          "sub" => client.id,
          "aud" => "http://www.example.com",
          "exp" => Keys.now(60),
          "jti" => Keys.jti()
        }

        b64 = &Base.url_encode64(&1, padding: false)

        input =
          b64.(JSON.encode!(%{"alg" => "HS256", "kid" => "k1"})) <>
            "." <> b64.(JSON.encode!(claims))

        input <> "." <> b64.(:crypto.mac(:hmac, :sha256, secret, input))
      end

      {secret_client, secret} = secret_client(config)

      rsa_pem = Keys.pem(:rsa)
      {:ok, rsa} = JWT.private_key(rsa_pem)
      rsa_jwk = Map.put(JWT.public_jwk(rsa), "kid", "k1")

      {:ok, rsa_client, nil} =
        Clients.create(config, %{
          name: "RSA",
          grant_types: ["client_credentials"],
          jwks: %{"keys" => [rsa_jwk]}
        })

      {ec_client, ec} = key_client(config)
      ec_jwk = Map.put(JWT.public_jwk(ec), "kid", "k1")

      for {client, key} <- [
            {secret_client, secret},
            {rsa_client, JSON.encode!(rsa_jwk)},
            {ec_client, JSON.encode!(ec_jwk)}
          ] do
        assert_invalid_client(
          post(
            grant(%{
              "client_assertion_type" => @assertion_type,
              "client_assertion" => hs256.(client, key)
            })
          )
        )
      end

      # The same clients get in with what they are registered for.
      assert post(grant(), [basic(secret_client.id, secret)]).status == 200

      assert post(
               grant(%{
                 "client_assertion_type" => @assertion_type,
                 "client_assertion" => assertion(rsa_client, rsa)
               })
             ).status == 200
    end

    test "keys at a jwks_uri are fetched, cached, and refetched for a new kid", %{config: config} do
      {key, jwk} = Keys.key(:ec, "k1")
      {base, docs} = Keys.serve(%{"/jwks" => %{"keys" => [jwk]}})

      {:ok, client, nil} =
        Clients.create(config, %{
          name: "Fetcher",
          grant_types: ["client_credentials"],
          jwks_uri: base <> "/jwks"
        })

      params = fn jwt ->
        grant(%{"client_assertion_type" => @assertion_type, "client_assertion" => jwt})
      end

      assert post(params.(assertion(client, key))).status == 200
      assert_received {:document_served, "/jwks"}
      assert post(params.(assertion(client, key))).status == 200
      refute_received {:document_served, "/jwks"}

      # The client rotates to a new key. Within a minute of the last
      # fetch, an unknown kid does not refetch.
      {new_key, new_jwk} = Keys.key(:ec, "k2")
      Keys.put(docs, "/jwks", %{"keys" => [new_jwk]})

      rotated = fn ->
        Keys.sign(
          %{
            "iss" => client.id,
            "sub" => client.id,
            "aud" => "http://www.example.com",
            "exp" => Keys.now(60),
            "jti" => Keys.jti()
          },
          new_key,
          %{"kid" => "k2"}
        )
      end

      assert_invalid_client(post(params.(rotated.())))
      refute_received {:document_served, "/jwks"}

      # Later, it does.
      Cache.put({:jwks, base <> "/jwks"}, {[jwk], Keys.now(-120)}, 3600)
      assert post(params.(rotated.())).status == 200
      assert_received {:document_served, "/jwks"}
    end

    test "registration rules for keys", %{config: config} do
      {_key, jwk} = Keys.key()
      base = %{name: "K", grant_types: ["client_credentials"]}

      assert {:error, %{jwks: _}} =
               Clients.create(config, Map.merge(base, %{jwks: %{"keys" => []}}))

      assert {:error, %{jwks: _}} =
               Clients.create(
                 config,
                 Map.merge(base, %{jwks: %{"keys" => [Map.put(jwk, "d", "x")]}})
               )

      assert {:error, %{jwks: _}} =
               Clients.create(
                 config,
                 Map.merge(base, %{jwks: %{"keys" => [jwk]}, confidential: true})
               )

      assert {:error, %{jwks: _}} =
               Clients.create(
                 config,
                 Map.merge(base, %{jwks: %{"keys" => [jwk]}, jwks_uri: "https://a.example/jwks"})
               )

      assert {:error, %{jwks_uri: _}} =
               Clients.create(config, Map.merge(base, %{jwks_uri: "ftp://a"}))

      assert {:error, %{grant_types: "client_credentials needs a confidential client" <> _}} =
               Clients.create(config, base)

      assert {:error, %{grant_types: _}} =
               Clients.create(config, %{base | grant_types: ["implicit"]})

      # A machine client needs no redirect URI; a code client still does.
      assert {:error, %{redirect_uris: "must not be empty"}} =
               Clients.create(config, %{name: "W", grant_types: ["authorization_code"]})
    end
  end

  describe "the token" do
    test "reaches the endpoint as the client's principal, until the client is gone", %{
      config: config
    } do
      {client, secret} = secret_client(config, %{scopes: ["issues:read"]})
      access = body(post(grant(), [basic(client.id, secret)]))["access_token"]

      call = fn ->
        ModernClient.post(ModernClient.opts(auth: true), "tools/list", %{},
          headers: [{"authorization", "Bearer " <> access}]
        )
      end

      conn = call.()
      assert conn.status == 200
      assert %{client: true, id: id} = conn.assigns.sake_scope
      assert id == client.id
      assert %{subject_id: nil} = conn.assigns.sake_token

      assert Sake.Tasks.principal(%Sake.Context{token: conn.assigns.sake_token}) ==
               "client:" <> client.id

      :ok = Clients.delete(config, client.id)
      assert call.().status == 401
    end

    test "can be revoked by its client", %{config: config} do
      {client, secret} = secret_client(config)
      access = body(post(grant(), [basic(client.id, secret)]))["access_token"]

      conn =
        conn(:post, "/oauth/revoke", URI.encode_query(%{"token" => access}))
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("authorization", elem(basic(client.id, secret), 1))
        |> Sake.Auth.Revoke.call([])

      assert conn.status == 200
      {mod, state} = Sake.Auth.store(config)

      assert {:ok, %{revoked_at: %DateTime{}}} =
               mod.get_token(state, :access, Tokens.hash(access))
    end
  end
end
