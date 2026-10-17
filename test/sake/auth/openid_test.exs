defmodule Sake.Auth.OpenIDTest do
  # OpenID Connect (#72): the signing keys and their JWK Set, the ID
  # token of the code, device and refresh grants, the userinfo endpoint
  # and the OpenID Provider metadata. Every ID token is verified with
  # JOSE directly, against the JWK Set the endpoint serves, and never
  # through Sake's own JWT code.
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.{Authorize, Config, Device, DPoP, JWT, Metadata, SigningKeys, Subject}
  alias SakeTest.Keys

  @rsa Keys.pem(:rsa)
  @ec Keys.pem(:ec)

  @moduletag auth: [
               openid: true,
               signing_keys: [[kid: "k1", pem: @rsa]],
               device: true,
               par: true
             ]

  @issuer "http://www.example.com"
  @resource "http://www.example.com/mcp"
  @userinfo "http://www.example.com/oauth/userinfo"
  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @device_code "urn:ietf:params:oauth:grant-type:device_code"

  # ---- helpers

  defp router(conn), do: Sake.Auth.RouterPlug.call(conn, Sake.Auth.RouterPlug.init([]))

  defp form(path, params, headers \\ []) do
    conn =
      conn(:post, path, URI.encode_query(params))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  defp params(client, extra) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_challenge" => @challenge,
        "code_challenge_method" => "S256",
        "state" => "xyz",
        "scope" => "openid issues:read",
        "resource" => @resource
      },
      extra
    )
    |> Map.reject(fn {_k, v} -> v == nil end)
  end

  @session %{user_id: "u1", acr: "mfa", auth_time: 1_760_000_000}

  defp authorize(query, session \\ @session) do
    conn(:get, "/oauth/authorize", query)
    |> init_test_session(session)
    |> Authorize.call(Authorize.init([]))
  end

  defp approve(conn, session \\ @session) do
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, conn.resp_body)

    conn(:post, "/oauth/authorize", %{"decision" => "approve", "request" => request})
    |> init_test_session(session)
    |> Authorize.call(Authorize.init([]))
  end

  defp code(conn) do
    [location] = get_resp_header(conn, "location")
    %{"code" => code} = URI.decode_query(URI.parse(location).query)
    code
  end

  # The code flow, through the authorize and token endpoints.
  defp code_flow(client, extra \\ %{}) do
    conn = authorize(params(client, extra))

    # A remembered consent issues the code at once.
    code =
      case conn.status do
        302 -> code(conn)
        200 -> conn |> approve() |> code()
      end

    exchange(client, code)
  end

  defp exchange(client, code) do
    conn =
      form("/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => @verifier,
        "client_id" => client.id
      })
      |> router()

    assert conn.status == 200, conn.resp_body
    body(conn)
  end

  defp refresh(client, refresh_token) do
    conn =
      form("/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => client.id
      })
      |> router()

    assert conn.status == 200, conn.resp_body
    body(conn)
  end

  defp jwks do
    conn = router(conn(:get, "/jwks"))
    assert conn.status == 200
    body(conn)
  end

  # Verifies an ID token with JOSE alone: the key its header names, from
  # the JWK Set the endpoint serves, with the algorithm the key states.
  defp verify!(id_token, set \\ jwks()) do
    header = id_token |> JOSE.JWS.peek_protected() |> JSON.decode!()
    assert header["typ"] == "JWT"
    jwk = Enum.find(set["keys"], &(&1["kid"] == header["kid"]))
    assert jwk, "no key #{header["kid"]} in the set"
    assert header["alg"] == jwk["alg"]

    assert {true, %JOSE.JWT{fields: claims}, _jws} =
             JOSE.JWT.verify_strict(JOSE.JWK.from_map(jwk), [jwk["alg"]], id_token)

    {header, claims}
  end

  defp at_hash(access_token, hash \\ :sha256) do
    digest = :crypto.hash(hash, access_token)
    digest |> binary_part(0, div(byte_size(digest), 2)) |> Base.url_encode64(padding: false)
  end

  defp userinfo(token, method \\ :get, headers \\ []) do
    conn = conn(method, "/userinfo")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn
    |> then(&Enum.reduce(headers, &1, fn {k, v}, c -> put_req_header(c, k, v) end))
    |> router()
  end

  defp person(id) do
    {:ok, person} = SakeDev.Accounts.get(id)
    person
  end

  # ---- signing keys

  describe "signing keys" do
    test "the JWK Set holds the public parts, with kid, alg and use" do
      assert %{"keys" => [jwk]} = jwks()
      assert %{"kid" => "k1", "alg" => "RS256", "use" => "sig", "kty" => "RSA"} = jwk
      assert Map.keys(jwk) |> Enum.sort() == ~w(alg e kid kty n use)
    end

    test "a P-256 key signs ES256, and its JWK has no private part" do
      [key] = SigningKeys.new([[kid: "ec", pem: @ec]], true)
      assert key.alg == "ES256"
      config = %{Sake.Auth.config() | signing_keys: [key]}
      assert %{"keys" => [jwk]} = SigningKeys.jwks(config)
      assert Map.keys(jwk) |> Enum.sort() == ~w(alg crv kid kty use x y)
    end

    test "the configuration is checked at start" do
      assert_raise ArgumentError, ~r/needs signing_keys/, fn -> SigningKeys.new([], true) end

      assert_raise ArgumentError, ~r/add openid: true/, fn ->
        SigningKeys.new([[kid: "k", pem: @rsa]], false)
      end

      assert_raise ArgumentError, ~r/kid of its own/, fn ->
        SigningKeys.new([[kid: "k", pem: @rsa], %{kid: "k", pem: @ec}], true)
      end

      assert_raise ArgumentError, ~r/must be a PEM private key/, fn ->
        SigningKeys.new([[kid: "k", pem: "not a key"]], true)
      end

      assert_raise ArgumentError, ~r/each key is/, fn -> SigningKeys.new([@rsa], true) end
      assert_raise ArgumentError, ~r/each key is/, fn -> SigningKeys.new([[pem: @rsa]], true) end
    end

    test "openid: takes its options" do
      base = [
        subject: SakeDev.Subject,
        issuer: @issuer,
        allow_insecure: true,
        signing_keys: [[kid: "k", pem: @ec]]
      ]

      assert %Config{openid: %{id_token_ttl: 120}} =
               Config.new(base ++ [openid: [id_token_ttl: 120]])

      assert %Config{openid: %{id_token_ttl: 3600}} = Config.new(base ++ [openid: true])

      assert_raise ArgumentError, ~r/id_token_ttl/, fn ->
        Config.new(base ++ [openid: [id_token_ttl: 0]])
      end

      assert_raise ArgumentError, ~r/must be true, false/, fn ->
        Config.new(base ++ [openid: :yes])
      end

      assert_raise ArgumentError, ~r/needs signing_keys/, fn ->
        Config.new(subject: SakeDev.Subject, issuer: @issuer, allow_insecure: true, openid: true)
      end
    end
  end

  # ---- ID tokens

  describe "the code flow" do
    test "issues an ID token with the person, the client, the nonce and at_hash", %{
      config: config
    } do
      client = public_client(config)
      tokens = code_flow(client, %{"nonce" => "n-0S6_WzA2Mj"})

      assert %{"id_token" => id_token, "access_token" => access, "scope" => scope} = tokens
      assert scope == "openid issues:read"
      {header, claims} = verify!(id_token)
      assert header["kid"] == "k1"

      assert %{
               "iss" => @issuer,
               "sub" => "u1",
               "aud" => aud,
               "azp" => azp,
               "nonce" => "n-0S6_WzA2Mj",
               "acr" => "mfa",
               "auth_time" => 1_760_000_000,
               "at_hash" => at_hash
             } = claims

      assert aud == client.id and azp == client.id
      assert at_hash == at_hash(access)
      now = System.system_time(:second)
      assert claims["iat"] in (now - 5)..now
      assert claims["exp"] == claims["iat"] + config.openid.id_token_ttl
    end

    test "no nonce, no nonce claim; an unknown sign-in, no acr or auth_time", %{config: config} do
      client = public_client(config)
      conn = authorize(params(client, %{}), %{user_id: "u1"})
      tokens = conn |> approve(%{user_id: "u1"}) |> code() |> then(&exchange(client, &1))
      {_header, claims} = verify!(tokens["id_token"])
      refute Map.has_key?(claims, "nonce")
      refute Map.has_key?(claims, "acr")
      refute Map.has_key?(claims, "auth_time")
    end

    test "without openid in the scopes, no ID token", %{config: config} do
      client = public_client(config)
      tokens = code_flow(client, %{"scope" => "issues:read", "nonce" => "n"})
      refute Map.has_key?(tokens, "id_token")
    end

    test "a nonce must be a string of sensible length", %{config: config} do
      client = public_client(config)
      conn = authorize(params(client, %{"nonce" => String.duplicate("n", 513)}))
      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert %{"error" => "invalid_request"} = URI.decode_query(URI.parse(location).query)
    end

    test "the consent page asks for openid like any other scope", %{config: config} do
      client = public_client(config)
      conn = authorize(params(client, %{"scope" => "openid profile email issues:read"}))
      assert conn.status == 200
      assert conn.resp_body =~ "Know who you are"
      assert conn.resp_body =~ "See your email address"
    end

    test "a pushed request carries the nonce", %{config: config} do
      client = public_client(config)

      conn = form("/par", params(client, %{"nonce" => "pushed-nonce"})) |> router()
      assert conn.status == 201, conn.resp_body
      %{"request_uri" => request_uri} = body(conn)

      code =
        %{"client_id" => client.id, "request_uri" => request_uri}
        |> authorize()
        |> approve()
        |> code()

      {_header, claims} = verify!(exchange(client, code)["id_token"])
      assert claims["nonce"] == "pushed-nonce"
    end

    test "a request for openid alone may be for the userinfo endpoint", %{config: config} do
      client = public_client(config)

      tokens =
        code_flow(client, %{"scope" => "openid email", "resource" => @userinfo, "nonce" => "x"})

      assert %{"id_token" => _} = tokens
      conn = userinfo(tokens["access_token"])
      assert conn.status == 200
      assert %{"sub" => "u1", "email" => "ana@example.com"} = body(conn)
    end

    test "with several resources, a request for openid that names none is for userinfo", %{
      config: config
    } do
      client = public_client(config)
      tokens = code_flow(client, %{"scope" => "openid", "resource" => nil})
      {module, state} = Sake.Auth.store(config)
      hash = Sake.Auth.Tokens.hash(tokens["access_token"])
      {:ok, record} = module.get_token(state, :access, hash)
      assert record.resource == @userinfo
    end
  end

  describe "refresh" do
    test "issues a new ID token with the original auth_time, and no nonce", %{config: config} do
      client = public_client(config)
      first = code_flow(client, %{"nonce" => "n1"})
      {_h, original} = verify!(first["id_token"])

      second = refresh(client, first["refresh_token"])
      assert %{"id_token" => id_token, "access_token" => access} = second
      {_h, claims} = verify!(id_token)

      assert claims["sub"] == original["sub"]
      assert claims["auth_time"] == original["auth_time"]
      assert claims["acr"] == "mfa"
      assert claims["at_hash"] == at_hash(access)
      refute Map.has_key?(claims, "nonce")
    end

    test "a refresh narrowed without openid has no ID token", %{config: config} do
      client = public_client(config)
      first = code_flow(client)

      conn =
        form("/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => first["refresh_token"],
          "client_id" => client.id,
          "scope" => "issues:read"
        })
        |> router()

      refute Map.has_key?(body(conn), "id_token")
    end
  end

  describe "key rotation" do
    test "the first key signs, every key is published, and old ID tokens still verify", %{
      config: config
    } do
      client = public_client(config)
      old = code_flow(client)["id_token"]

      # The new key goes first; the old one stays published.
      rotated = SigningKeys.new([[kid: "k2", pem: @ec], [kid: "k1", pem: @rsa]], true)
      :persistent_term.put({Sake.Auth, :config}, %{config | signing_keys: rotated})

      set = jwks()
      assert Enum.map(set["keys"], & &1["kid"]) == ["k2", "k1"]

      new = code_flow(client)
      {header, claims} = verify!(new["id_token"], set)
      assert header == %{"alg" => "ES256", "kid" => "k2", "typ" => "JWT"}
      assert claims["at_hash"] == at_hash(new["access_token"])

      assert {%{"kid" => "k1"}, _claims} = verify!(old, set)
    end

    test "at_hash follows the algorithm: SHA-384 for ES384" do
      assert Sake.Auth.IDToken.at_hash("token", "ES384") == at_hash("token", :sha384)
      assert Sake.Auth.IDToken.at_hash("token", "RS256") == at_hash("token")
    end
  end

  describe "the device flow" do
    test "gets an ID token without a nonce", %{config: config} do
      client =
        public_client(config, %{
          name: "Device CLI",
          redirect_uris: [],
          grant_types: [@device_code, "refresh_token"]
        })

      {:ok, %{"device_code" => device_code, "user_code" => user_code}} =
        Device.start(config, client, %{
          "scope" => "openid issues:read",
          "resource" => @resource,
          "nonce" => "ignored"
        })

      at = ~U[2026-10-01 08:00:00Z]

      :ok =
        Device.decide(config, user_code, person("u1"), :approve, %{acr: "pwd", auth_time: at})

      conn =
        form("/token", %{
          "grant_type" => @device_code,
          "device_code" => device_code,
          "client_id" => client.id
        })
        |> router()

      assert conn.status == 200, conn.resp_body
      tokens = body(conn)
      {_h, claims} = verify!(tokens["id_token"])

      assert %{"sub" => "u1", "aud" => aud, "acr" => "pwd", "auth_time" => auth_time} = claims
      assert aud == client.id
      assert auth_time == DateTime.to_unix(at)
      assert claims["at_hash"] == at_hash(tokens["access_token"])
      refute Map.has_key?(claims, "nonce")
    end
  end

  # ---- userinfo

  describe "userinfo" do
    test "returns sub and the claims for the token's scopes, by GET and POST", %{
      config: config
    } do
      %{"access_token" => profile} =
        code_flow(public_client(config), %{"scope" => "openid profile issues:read"})

      conn = userinfo(profile)
      assert conn.status == 200
      assert body(conn) == %{"sub" => "u1", "name" => "Ana Lima"}
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      %{"access_token" => email} =
        code_flow(public_client(config), %{"scope" => "openid email"})

      conn = userinfo(email, :post)
      assert conn.status == 200

      assert body(conn) == %{
               "sub" => "u1",
               "email" => "ana@example.com",
               "email_verified" => true
             }
    end

    test "a token without openid gets insufficient_scope, as an OAuth error", %{config: config} do
      %{"access_token" => token} = code_flow(public_client(config), %{"scope" => "issues:read"})
      conn = userinfo(token)
      assert conn.status == 403
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(Bearer error="insufficient_scope")
      assert challenge =~ ~s(scope="openid")
      assert %{"error" => "insufficient_scope"} = body(conn)
    end

    test "no token, or an unknown one, gets a 401 with a JSON error" do
      conn = userinfo(nil)
      assert conn.status == 401
      assert [bearer | _] = get_resp_header(conn, "www-authenticate")
      assert bearer =~ ~s(Bearer )
      assert bearer =~ ~s(scope="openid")
      assert %{"error" => "invalid_token"} = body(conn)

      conn = userinfo("nope")
      assert conn.status == 401
      assert %{"error" => "invalid_token"} = body(conn)
    end

    test "a DPoP-bound token comes with a proof for the userinfo URL", %{config: config} do
      pem = DPoP.generate_key()
      {:ok, key} = JWT.private_key(pem)
      jkt = key |> JWT.public_jwk() |> JWT.thumbprint()

      token =
        Sake.Auth.issue_access_token(config, %{
          client_id: "c",
          subject_id: "u1",
          scopes: ["openid", "email"],
          resource: @resource,
          jkt: jkt
        })

      assert userinfo(token).status == 401

      proof = DPoP.proof(key, "GET", "http://www.example.com/userinfo", access_token: token)

      conn =
        conn(:get, "/userinfo")
        |> put_req_header("authorization", "DPoP " <> token)
        |> put_req_header("dpop", proof)
        |> router()

      assert conn.status == 200, conn.resp_body
      assert %{"sub" => "u1", "email" => "ana@example.com"} = body(conn)
    end

    test "claims/2 is optional, and answers for the scopes it is given" do
      assert Subject.claims(SakeDev.Subject, person("u1"), ["openid"]) == %{}
      assert Subject.claims(Sake.Auth.Store.ETS, person("u1"), ["email"]) == %{}
    end
  end

  # ---- metadata

  describe "metadata" do
    test "the authorization server lists the OpenID scopes and the JWKS", %{config: config} do
      metadata = Metadata.authorization_server(config)
      assert metadata["jwks_uri"] == "http://www.example.com/oauth/jwks"
      assert ~w(openid profile email) -- metadata["scopes_supported"] == []
    end

    test "the OpenID Provider metadata is served from the same map" do
      conn = Sake.Auth.WellKnown.call(conn(:get, "/openid-configuration"), [])
      assert conn.status == 200
      metadata = body(conn)

      assert %{
               "issuer" => @issuer,
               "authorization_endpoint" => "http://www.example.com/oauth/authorize",
               "token_endpoint" => "http://www.example.com/oauth/token",
               "userinfo_endpoint" => @userinfo,
               "jwks_uri" => "http://www.example.com/oauth/jwks",
               "subject_types_supported" => ["public"],
               "id_token_signing_alg_values_supported" => ["RS256"],
               "response_types_supported" => ["code"]
             } = metadata

      assert "email" in metadata["claims_supported"]
      assert Map.delete(metadata, "claims_supported") |> Map.keys() |> length() > 10
    end

    test "the protected resource metadata does not list the OpenID scopes", %{config: config} do
      metadata = Metadata.protected_resource(config, @resource)
      refute "openid" in metadata["scopes_supported"]
    end
  end
end

defmodule Sake.Auth.OpenIDOffTest do
  # Without `openid:`, nothing changes: no endpoints, no metadata, no
  # OpenID scopes, and a nonce is ignored.
  use SakeTest.AuthCase, async: false
  import Plug.Test

  alias Sake.Auth.{AuthorizationRequest, Metadata}

  defp router(conn), do: Sake.Auth.RouterPlug.call(conn, Sake.Auth.RouterPlug.init([]))

  test "the endpoints and the discovery document are not there" do
    assert router(conn(:get, "/jwks")).status == 404
    assert router(conn(:get, "/userinfo")).status == 404
    assert Sake.Auth.WellKnown.call(conn(:get, "/openid-configuration"), []).status == 404
  end

  test "the metadata says nothing of OpenID Connect", %{config: config} do
    metadata = Metadata.authorization_server(config)
    refute Map.has_key?(metadata, "jwks_uri")
    refute "openid" in metadata["scopes_supported"]
    assert Metadata.openid_configuration(config) == nil
  end

  test "openid is an unknown scope, and a nonce is ignored", %{config: config} do
    client = public_client(config)

    p = %{
      "response_type" => "code",
      "client_id" => client.id,
      "redirect_uri" => hd(client.redirect_uris),
      "code_challenge" => "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
      "code_challenge_method" => "S256",
      "resource" => "http://www.example.com/mcp",
      "nonce" => "n"
    }

    assert {:error, "invalid_scope", _} =
             AuthorizationRequest.validate(config, client, Map.put(p, "scope", "openid"))

    assert {:ok, %{extra: extra}} =
             AuthorizationRequest.validate(config, client, Map.put(p, "scope", "issues:read"))

    assert extra == %{}
  end
end
