defmodule Sake.Auth.DPoPTest do
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Sake.Auth.{Authorize, DPoP, JWT, Tokens}
  alias SakeTest.{Keys, ModernClient}

  @token_url "http://www.example.com/oauth/token"
  @mcp "http://www.example.com/mcp"
  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  # A proof with chosen claims and header, for the refusals.
  defp forged(key, claims, header \\ %{}) do
    %{"jti" => Keys.jti(), "htm" => "POST", "htu" => @mcp, "iat" => Keys.now()}
    |> Map.merge(claims)
    |> Map.reject(fn {_, v} -> is_nil(v) end)
    |> Keys.sign(key, Map.merge(%{"typ" => "dpop+jwt", "jwk" => JWT.public_jwk(key)}, header))
  end

  # A token no signing function would make: an HMAC algorithm.
  defp unsigned(header, claims) do
    Enum.map_join([header, claims], ".", &Base.url_encode64(JSON.encode!(&1), padding: false)) <>
      ".c2ln"
  end

  defp check(proof, opts \\ []),
    do: DPoP.verify(proof, Keyword.merge([htm: "POST", htu: [@mcp]], opts))

  describe "proofs" do
    test "a proof verifies and gives the thumbprint of its key" do
      {key, jwk} = Keys.key()
      proof = DPoP.proof(key, "POST", @mcp <> "?q=1#f", access_token: "tok", nonce: "n1")

      assert {:ok, header, claims} = JWT.peek(proof)
      assert header["typ"] == "dpop+jwt" and header["alg"] == "ES256" and header["jwk"] == jwk
      refute Map.has_key?(header["jwk"], "d")
      assert claims["htm"] == "POST" and claims["htu"] == @mcp
      assert claims["ath"] == DPoP.ath("tok") and claims["nonce"] == "n1"
      assert is_binary(claims["jti"]) and is_integer(claims["iat"])

      assert {:ok, jkt} = check(proof, access_token: "tok")
      assert jkt == JWT.thumbprint(jwk)
    end

    test "every client key makes a working proof: P-256, P-384 and RSA" do
      for kind <- [:ec, :p384, :rsa] do
        {key, jwk} = Keys.key(kind)
        assert {:ok, jkt} = check(DPoP.proof(key, "POST", @mcp)), inspect(kind)
        assert jkt == JWT.thumbprint(jwk)
      end

      {:ok, key} = JWT.private_key(DPoP.generate_key())
      assert JWT.default_alg(key) == "ES256"
    end

    test "the RFC 7638 thumbprint, and jose's for an EC key" do
      jwk = %{
        "kty" => "RSA",
        "n" =>
          "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
        "e" => "AQAB",
        "alg" => "RS256",
        "kid" => "2011-04-29"
      }

      assert JWT.thumbprint(jwk) == "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"

      {_key, ec} = Keys.key()
      assert JWT.thumbprint(Map.put(ec, "kid", "x")) == JOSE.JWK.thumbprint(JOSE.JWK.from_map(ec))
    end

    test "htu is compared without query, fragment, default port or case" do
      assert DPoP.htu("HTTPS://Example.COM:443/mcp?x=1#y") == "https://example.com/mcp"
      assert DPoP.htu("http://example.com:8080") == "http://example.com:8080/"
      assert DPoP.htu("http://[::1]:4000/mcp") == "http://[::1]:4000/mcp"

      {key, _} = Keys.key()
      assert {:ok, _} = check(forged(key, %{"htu" => "http://WWW.example.com:80/mcp?a=b"}))
    end

    test "every bad proof is invalid_dpop_proof" do
      {key, jwk} = Keys.key()
      {other, _} = Keys.key()
      good = %{"typ" => "dpop+jwt", "jwk" => jwk}

      tampered =
        key
        |> forged(%{})
        |> String.split(".")
        |> List.update_at(1, fn _ ->
          Base.url_encode64(JSON.encode!(%{"jti" => "x", "htm" => "GET"}), padding: false)
        end)
        |> Enum.join(".")

      private = Map.merge(jwk, %{"d" => "AAAA"})

      for {proof, opts, why} <- [
            {"not.a.jwt", [], "not a JWT"},
            {forged(key, %{}, %{"typ" => "JWT"}), [], "typ"},
            {forged(key, %{}, %{"jwk" => nil}), [], "jwk header"},
            {forged(key, %{}, %{"jwk" => private}), [], "public key"},
            {unsigned(Map.put(good, "alg", "HS256"), %{"jti" => "1"}), [], "alg"},
            {forged(other, %{}, %{"jwk" => jwk}), [], "signature"},
            {tampered, [], "signature"},
            {forged(key, %{"jti" => nil}), [], "jti"},
            {forged(key, %{"jti" => 7}), [], "strings"},
            {forged(key, %{"htm" => "GET"}), [], "htm"},
            {forged(key, %{"htu" => "http://www.example.com/other"}), [], "htu"},
            {forged(key, %{"htu" => "https://www.example.com/mcp"}), [], "htu"},
            {forged(key, %{"iat" => Keys.now(-400)}), [], "too old"},
            {forged(key, %{"iat" => Keys.now(120)}), [], "future"},
            {forged(key, %{}), [access_token: "tok"], "no ath"},
            {forged(key, %{"ath" => DPoP.ath("other")}), [access_token: "tok"], "ath"},
            {String.duplicate("a", 9_000), [], "too large"}
          ] do
        assert {:error, "invalid_dpop_proof", description} = check(proof, opts), why
        assert description =~ why, "#{why}: #{description}"
      end
    end

    test "a proof is accepted once" do
      {key, _} = Keys.key()
      proof = DPoP.proof(key, "POST", @mcp)
      assert {:ok, _} = check(proof)
      assert {:error, "invalid_dpop_proof", "The DPoP proof was already used"} = check(proof)

      # The same jti from another key is another proof.
      {other, _} = Keys.key()
      assert {:ok, _} = check(forged(other, %{"jti" => "same"}))
      assert {:ok, _} = check(forged(key, %{"jti" => "same"}))
    end

    test "nonces: the current one and the one before are good, older ones are not" do
      secret = String.duplicate("k", 32)
      now = 1_000_000
      nonce = DPoP.nonce(secret, now)

      assert DPoP.valid_nonce?(secret, nonce, now)
      assert DPoP.valid_nonce?(secret, nonce, now + 300)
      refute DPoP.valid_nonce?(secret, nonce, now + 600)
      refute DPoP.valid_nonce?(String.duplicate("j", 32), nonce, now)

      {key, _} = Keys.key()

      assert {:error, "use_dpop_nonce", _} = check(forged(key, %{}), nonce: secret)

      assert {:error, "use_dpop_nonce", _} =
               check(forged(key, %{"nonce" => "stale"}), nonce: secret)

      # A proof refused for its nonce is not recorded: the client's next
      # proof may even reuse its jti.
      proof = forged(key, %{"jti" => "retry", "nonce" => DPoP.nonce(secret)})

      assert {:error, "use_dpop_nonce", _} =
               check(forged(key, %{"jti" => "retry"}), nonce: secret)

      assert {:ok, _} = check(proof, nonce: secret)
    end

    test "several proofs in one request are refused" do
      conn = conn(:post, "/") |> put_req_header("dpop", "a.b.c, d.e.f")
      assert {:error, "invalid_dpop_proof", _} = DPoP.from_conn(conn)

      conn = %{conn(:post, "/") | req_headers: [{"dpop", "a.b.c"}, {"dpop", "d.e.f"}]}
      assert {:error, "invalid_dpop_proof", _} = DPoP.from_conn(conn)
      assert :none = DPoP.from_conn(conn(:post, "/"))
    end
  end

  # ---- the token endpoint

  defp token(params, headers) do
    conn =
      conn(:post, "/oauth/token", URI.encode_query(params))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Sake.Auth.Token.call(conn, Sake.Auth.Token.init([]))
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  defp proof_for(key, opts \\ []), do: {"dpop", DPoP.proof(key, "POST", @token_url, opts)}

  defp code_params(config, client) do
    code =
      Authorize.issue_code(
        config,
        %{
          client_id: client.id,
          redirect_uri: hd(client.redirect_uris),
          code_challenge: @challenge,
          scopes: ["issues:read"],
          resource: @mcp
        },
        "u1"
      )

    %{
      "grant_type" => "authorization_code",
      "code" => code,
      "client_id" => client.id,
      "redirect_uri" => hd(client.redirect_uris),
      "code_verifier" => @verifier
    }
  end

  defp record(config, kind, token) do
    {mod, state} = Sake.Auth.store(config)
    {:ok, record} = mod.get_token(state, kind, Tokens.hash(token))
    record
  end

  describe "the token endpoint" do
    test "a proof binds the pair to its key; a public client refreshes with that key only", %{
      config: config
    } do
      client = public_client(config)
      {key, jwk} = Keys.key()
      jkt = JWT.thumbprint(jwk)

      conn = token(code_params(config, client), [proof_for(key)])
      assert conn.status == 200
      assert %{"token_type" => "DPoP", "access_token" => a1, "refresh_token" => r1} = body(conn)
      assert record(config, :access, a1).jkt == jkt
      assert record(config, :refresh, r1).jkt == jkt

      refresh = %{
        "grant_type" => "refresh_token",
        "refresh_token" => r1,
        "client_id" => client.id
      }

      # Without a proof, or with another key, the refresh token is refused
      # (and, being single use, spent: a thief's try shows as reuse).
      {other, _} = Keys.key()
      conn = token(refresh, [proof_for(other)])
      assert conn.status == 400
      assert body(conn)["error_description"] =~ "bound to another DPoP key"

      %{"refresh_token" => r2} = body(token(code_params(config, client), [proof_for(key)]))
      conn = token(%{refresh | "refresh_token" => r2}, [])
      assert conn.status == 400
      assert body(conn)["error_description"] =~ "send a proof"

      %{"refresh_token" => r3} = body(token(code_params(config, client), [proof_for(key)]))
      conn = token(%{refresh | "refresh_token" => r3}, [proof_for(key)])
      assert conn.status == 200
      assert %{"token_type" => "DPoP", "access_token" => a4, "refresh_token" => r4} = body(conn)
      assert record(config, :access, a4).jkt == jkt
      assert record(config, :refresh, r4).jkt == jkt
    end

    test "a confidential client's refresh token is bound to its secret, not the key", %{
      config: config
    } do
      {:ok, client, secret} =
        Sake.Auth.Clients.create(config, %{
          name: "Web",
          redirect_uris: ["https://app.example/cb"],
          confidential: true
        })

      basic = {"authorization", "Basic " <> Base.encode64(client.id <> ":" <> secret)}
      {key, _} = Keys.key()
      conn = token(code_params(config, client), [basic, proof_for(key)])
      assert %{"token_type" => "DPoP", "refresh_token" => r1} = body(conn)
      assert record(config, :refresh, r1).jkt == nil

      {other, other_jwk} = Keys.key()
      refresh = %{"grant_type" => "refresh_token", "refresh_token" => r1}
      conn = token(refresh, [basic, proof_for(other)])
      assert %{"token_type" => "DPoP", "access_token" => a2, "refresh_token" => r2} = body(conn)
      assert record(config, :access, a2).jkt == JWT.thumbprint(other_jwk)

      conn = token(%{refresh | "refresh_token" => r2}, [basic])
      assert %{"token_type" => "Bearer", "access_token" => a3} = body(conn)
      assert record(config, :access, a3).jkt == nil
    end

    test "a bad proof is refused before the code is spent", %{config: config} do
      client = public_client(config)
      {key, _} = Keys.key()
      params = code_params(config, client)

      for proof <- [
            DPoP.proof(key, "GET", @token_url),
            DPoP.proof(key, "POST", "http://www.example.com/oauth/other"),
            forged(key, %{"htu" => @token_url, "iat" => Keys.now(-600)})
          ] do
        conn = token(params, [{"dpop", proof}])
        assert conn.status == 400
        assert body(conn)["error"] == "invalid_dpop_proof"
      end

      assert token(params, [{"dpop", "a.b.c, d.e.f"}]).status == 400

      proof = proof_for(key)
      assert token(params, [proof]).status == 200

      # A replayed proof is refused even with a fresh code.
      conn = token(code_params(config, client), [proof])
      assert conn.status == 400 and body(conn)["error_description"] =~ "already used"
    end

    test "a proof is recorded only once the client is authenticated", %{config: config} do
      {:ok, client, secret} =
        Sake.Auth.Clients.create(config, %{
          name: "Web",
          redirect_uris: ["https://app.example/cb"],
          confidential: true
        })

      basic = fn secret ->
        {"authorization", "Basic " <> Base.encode64(client.id <> ":" <> secret)}
      end

      {key, _} = Keys.key()
      proof = proof_for(key)
      params = code_params(config, client)

      # Refused for its client: the proof is not spent, nor the code.
      conn = token(params, [basic.("wrong"), proof])
      assert conn.status == 401 and body(conn)["error"] == "invalid_client"
      assert token(params, [basic.(secret), proof]).status == 200

      # Replayed by the authenticated client: refused, and the code it came
      # with is not spent either.
      fresh = code_params(config, client)
      conn = token(fresh, [basic.(secret), proof])
      assert conn.status == 400 and body(conn)["error_description"] =~ "already used"
      assert token(fresh, [basic.(secret), proof_for(key)]).status == 200
    end

    test "the client credentials grant binds its token too", %{config: config} do
      {:ok, client, secret} =
        Sake.Auth.Clients.create(config, %{
          name: "Nightly",
          grant_types: ["client_credentials"],
          confidential: true
        })

      {key, jwk} = Keys.key()

      conn =
        token(%{"grant_type" => "client_credentials", "resource" => @mcp}, [
          {"authorization", "Basic " <> Base.encode64(client.id <> ":" <> secret)},
          proof_for(key)
        ])

      assert %{"token_type" => "DPoP", "access_token" => access} = body(conn)
      assert record(config, :access, access).jkt == JWT.thumbprint(jwk)
    end

    @tag auth: [dpop: [nonce: true]]
    test "a server that requires nonces asks for one, and the code survives the round", %{
      config: config
    } do
      client = public_client(config)
      {key, _} = Keys.key()
      params = code_params(config, client)

      conn = token(params, [proof_for(key)])
      assert conn.status == 400
      assert %{"error" => "use_dpop_nonce"} = body(conn)
      assert [nonce] = get_resp_header(conn, "dpop-nonce")

      conn = token(params, [proof_for(key, nonce: "made-up")])
      assert body(conn)["error"] == "use_dpop_nonce"

      conn = token(params, [proof_for(key, nonce: nonce)])
      assert conn.status == 200
      assert body(conn)["token_type"] == "DPoP"
      assert [_latest] = get_resp_header(conn, "dpop-nonce")

      # A request without a proof needs no nonce: it gets a bearer token.
      assert %{"token_type" => "Bearer"} = body(token(code_params(config, client), []))
    end

    @tag auth: [dpop: false]
    test "a server without DPoP ignores the proof and issues bearer tokens", %{config: config} do
      {key, _} = Keys.key()
      conn = token(code_params(config, public_client(config)), [proof_for(key)])
      assert %{"token_type" => "Bearer", "access_token" => access} = body(conn)
      assert record(config, :access, access).jkt == nil
    end
  end

  # ---- the resource server

  defp opts, do: ModernClient.opts(auth: true)

  defp bound(config, attrs \\ %{}) do
    {key, jwk} = Keys.key()

    {access, _, _} =
      issue(config, Map.merge(%{scopes: ["issues:read"], jkt: JWT.thumbprint(jwk)}, attrs))

    {access, key}
  end

  defp mcp(headers, method \\ "tools/list", params \\ %{}),
    do: ModernClient.post(opts(), method, params, headers: headers)

  defp dpop(access, key, opts \\ []) do
    [
      {"authorization", "DPoP " <> access},
      {"dpop", DPoP.proof(key, "POST", @mcp, Keyword.put_new(opts, :access_token, access))}
    ]
  end

  defp challenges(conn), do: get_resp_header(conn, "www-authenticate")

  describe "the resource server" do
    test "a bound token with a good proof is in; the proof is good once", %{config: config} do
      {access, key} = bound(config)
      headers = dpop(access, key)
      assert mcp(headers).status == 200

      conn = mcp(headers)
      assert conn.status == 401

      assert [
               ~s(DPoP error="invalid_dpop_proof", error_description="The DPoP proof was already used") <>
                 _,
               "Bearer " <> _
             ] =
               challenges(conn)

      for scheme <- ["DPoP", "dpop", "DPOP"] do
        conn =
          mcp([
            {"authorization", scheme <> " " <> access},
            {"dpop", DPoP.proof(key, "POST", @mcp, access_token: access)}
          ])

        assert conn.status == 200, scheme
      end
    end

    test "a wrong method, URL, token hash, key or age is refused", %{config: config} do
      {access, key} = bound(config)
      {other, _} = Keys.key()
      auth = {"authorization", "DPoP " <> access}

      for {proof, why} <- [
            {DPoP.proof(key, "GET", @mcp, access_token: access), "htm"},
            {DPoP.proof(key, "POST", "http://www.example.com/beta/mcp", access_token: access),
             "htu"},
            {DPoP.proof(key, "POST", @mcp, access_token: "another"), "ath"},
            {DPoP.proof(key, "POST", @mcp), "ath"},
            {DPoP.proof(other, "POST", @mcp, access_token: access), "key"},
            {forged(key, %{"iat" => Keys.now(-400), "ath" => DPoP.ath(access)}), "too old"}
          ] do
        conn = mcp([auth, {"dpop", proof}])
        assert conn.status == 401, why

        assert [~s(DPoP error="invalid_dpop_proof", error_description=) <> rest, _] =
                 challenges(conn)

        assert rest =~ why
      end

      conn = mcp([auth])
      assert [~s(DPoP error="invalid_dpop_proof") <> _, _] = challenges(conn)
    end

    test "a bound token sent as a bearer token is refused", %{config: config} do
      {access, _key} = bound(config)
      conn = mcp([{"authorization", "Bearer " <> access}])
      assert conn.status == 401

      assert [
               ~s(DPoP error="invalid_token", error_description="The access token is DPoP-bound: send it with a proof", resource_metadata=) <>
                 _,
               ~s(Bearer resource_metadata=) <> _
             ] = challenges(conn)
    end

    test "an unbound token with the DPoP scheme, or an unknown one, is refused", %{config: config} do
      {key, _} = Keys.key()
      {access, _, _} = issue(config, %{scopes: ["issues:read"]})

      conn = mcp(dpop(access, key))
      assert conn.status == 401
      assert [~s(Bearer error="invalid_token") <> _, "DPoP " <> _] = challenges(conn)

      conn = mcp(dpop("nope", key))
      assert conn.status == 401
      assert [~s(DPoP error="invalid_token") <> _, "Bearer " <> _] = challenges(conn)
    end

    test "a 403 for scopes is a DPoP challenge, so the client steps up with DPoP", %{
      config: config
    } do
      {access, key} = bound(config)

      conn =
        mcp(dpop(access, key), "tools/call", %{"name" => "slow", "arguments" => %{"n" => 1}})

      assert conn.status == 403

      assert [
               ~s(DPoP error="insufficient_scope", scope="issues:write", resource_metadata="http://www.example.com/.well-known/oauth-protected-resource/mcp", algs="RS256 PS256 ES256 ES384")
             ] = challenges(conn)
    end

    test "the legacy GET stream and DELETE are checked with their own method", %{
      config: config
    } do
      {access, key} = bound(config, %{scopes: ["issues:read", "issues:write"]})

      request = fn method, htm ->
        conn(method, "/mcp")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("authorization", "DPoP " <> access)
        |> put_req_header("dpop", DPoP.proof(key, htm, @mcp, access_token: access))
        |> Sake.Plug.call(opts())
      end

      assert request.(:delete, "DELETE").status == 405
      assert request.(:delete, "POST").status == 401
      assert request.(:get, "GET").status == 405
      assert request.(:get, "DELETE").status == 401
    end

    @tag auth: [dpop: [nonce: true]]
    test "a server that requires nonces challenges for one, and hands out the latest", %{
      config: config
    } do
      {access, key} = bound(config)

      conn = mcp(dpop(access, key))
      assert conn.status == 401
      assert [nonce] = get_resp_header(conn, "dpop-nonce")
      assert [~s(DPoP error="use_dpop_nonce") <> _, "Bearer " <> _] = challenges(conn)

      conn = mcp(dpop(access, key, nonce: nonce))
      assert conn.status == 200
      assert [_latest] = get_resp_header(conn, "dpop-nonce")

      # A bearer token needs no nonce.
      {bearer, _, _} = issue(config, %{scopes: ["issues:read"]})
      conn = mcp([{"authorization", "Bearer " <> bearer}])
      assert conn.status == 200
      assert get_resp_header(conn, "dpop-nonce") == []
    end

    @tag auth: [dpop: false]
    test "a server without DPoP refuses the scheme, and offers only Bearer", %{config: config} do
      {access, key} = bound(config)
      conn = mcp(dpop(access, key))
      assert conn.status == 401

      assert [
               ~s(Bearer error="invalid_request", error_description="This server does not take the DPoP scheme") <>
                 _
             ] = challenges(conn)

      # A token bound before DPoP was turned off still cannot go as Bearer.
      assert mcp([{"authorization", "Bearer " <> access}]).status == 401
    end
  end

  # ---- DPoP required

  defp confidential(config, attrs \\ %{}) do
    {:ok, client, secret} =
      Sake.Auth.Clients.create(
        config,
        Map.merge(
          %{
            name: "Web",
            redirect_uris: ["https://app.example/cb"],
            grant_types: ["authorization_code", "refresh_token", "client_credentials"],
            confidential: true
          },
          attrs
        )
      )

    {client, {"authorization", "Basic " <> Base.encode64(client.id <> ":" <> secret)}}
  end

  describe "dpop: [required: true]" do
    @describetag auth: [dpop: [required: true]]

    test "every grant refuses a request without a proof, before it spends anything", %{
      config: config
    } do
      {client, basic} = confidential(config)
      {key, _} = Keys.key()
      params = code_params(config, client)

      conn = token(params, [basic])
      assert conn.status == 400
      assert %{"error" => "invalid_dpop_proof", "error_description" => description} = body(conn)
      assert description =~ "DPoP-bound tokens only"

      # The code was not spent: with a proof it works.
      conn = token(params, [basic, proof_for(key)])
      assert %{"token_type" => "DPoP", "refresh_token" => refresh} = body(conn)

      refresh = %{"grant_type" => "refresh_token", "refresh_token" => refresh}
      assert body(token(refresh, [basic]))["error"] == "invalid_dpop_proof"
      assert %{"token_type" => "DPoP"} = body(token(refresh, [basic, proof_for(key)]))

      machine = %{"grant_type" => "client_credentials", "resource" => @mcp}
      assert body(token(machine, [basic]))["error"] == "invalid_dpop_proof"
      assert %{"token_type" => "DPoP"} = body(token(machine, [basic, proof_for(key)]))
    end

    test "the JWT bearer grant too" do
      {key, jwk} = Keys.key()
      stop_supervised!(Sake)

      start_supervised!(
        {Sake,
         auth: [
           subject: SakeDev.Subject,
           issuer: "http://www.example.com",
           allow_insecure: true,
           servers: [SakeDev.Server],
           resources: ["/mcp"],
           dpop: [required: true],
           trusted_issuers: [
             [
               issuer: "https://ci.example",
               profile: :workload,
               jwks: %{"keys" => [jwk]},
               audiences: ["https://mcp.example.com"],
               clients: :any
             ]
           ]
         ],
         secret_key_base: ModernClient.secret(),
         streams: false,
         tasks: false}
      )

      {:ok, client, nil} =
        Sake.Auth.Clients.create(Sake.Auth.config(), %{
          name: "Workload",
          grant_types: ["urn:ietf:params:oauth:grant-type:jwt-bearer"]
        })

      grant = fn ->
        assertion =
          Keys.sign(
            %{
              "iss" => "https://ci.example",
              "sub" => "repo:acme/app",
              "email" => "bo@example.com",
              "aud" => "https://mcp.example.com",
              "exp" => Keys.now(300)
            },
            key
          )

        %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
          "assertion" => assertion,
          "client_id" => client.id,
          "resource" => @mcp
        }
      end

      {proof_key, _} = Keys.key()
      assert body(token(grant.(), []))["error"] == "invalid_dpop_proof"
      assert %{"token_type" => "DPoP"} = body(token(grant.(), [proof_for(proof_key)]))
    end

    test "the MCP endpoint refuses Bearer, even an unbound token, and challenges DPoP only", %{
      config: config
    } do
      {unbound, _, _} = issue(config, %{scopes: ["issues:read"]})

      conn = mcp([{"authorization", "Bearer " <> unbound}])
      assert conn.status == 401

      assert [
               ~s(DPoP error="invalid_token", error_description="This server takes DPoP-bound tokens only", resource_metadata=) <>
                 _
             ] = challenges(conn)

      {key, _} = Keys.key()
      conn = mcp(dpop(unbound, key))

      assert [
               ~s(DPoP error="invalid_token", error_description="The access token is not DPoP-bound") <>
                 _
             ] =
               challenges(conn)

      conn = mcp([])
      assert [~s(DPoP resource_metadata=) <> _] = challenges(conn)

      {access, key} = bound(config)
      assert mcp(dpop(access, key)).status == 200
    end

    test "the resource metadata says so" do
      conn =
        conn(:get, "/.well-known/oauth-protected-resource/mcp")
        |> Sake.Auth.WellKnown.call(Sake.Auth.WellKnown.init([]))

      assert JSON.decode!(conn.resp_body)["dpop_bound_access_tokens_required"] == true
    end

    test "the option is checked when Sake starts" do
      for bad <- [[required: "yes"], [nonce: true, other: 1]] do
        assert_raise ArgumentError, ~r/dpop:/, fn ->
          Sake.Auth.Config.new(
            subject: SakeDev.Subject,
            issuer: "http://www.example.com",
            allow_insecure: true,
            dpop: bad
          )
        end
      end
    end
  end

  describe "a client registered with dpop_bound_access_tokens" do
    defp register(doc) do
      conn(:post, "/oauth/register", JSON.encode!(doc))
      |> put_req_header("content-type", "application/json")
      |> Sake.Auth.DCR.call(Sake.Auth.DCR.init([]))
    end

    test "dynamic registration keeps it, and the client's requests need a proof", %{
      config: config
    } do
      doc = %{"redirect_uris" => ["http://127.0.0.1:9000/callback"], "client_name" => "CLI"}

      assert register(Map.put(doc, "dpop_bound_access_tokens", "yes")).status == 400

      conn = register(Map.put(doc, "dpop_bound_access_tokens", true))
      assert %{"client_id" => id, "dpop_bound_access_tokens" => true} = body(conn)
      {:ok, client} = Sake.Auth.Clients.get(config, id)
      assert client.dpop_bound_access_tokens

      {key, _} = Keys.key()
      params = code_params(config, client)
      conn = token(params, [])
      assert %{"error" => "invalid_dpop_proof", "error_description" => description} = body(conn)
      assert description =~ "client's tokens must be DPoP-bound"
      assert %{"token_type" => "DPoP"} = body(token(params, [proof_for(key)]))

      # Another client of the same server still gets bearer tokens.
      assert %{"token_type" => "Bearer"} =
               body(token(code_params(config, public_client(config)), []))
    end

    test "a host-registered client may say so too", %{config: config} do
      {_client, basic} = confidential(config, %{dpop_bound_access_tokens: true})
      machine = %{"grant_type" => "client_credentials", "resource" => @mcp}
      assert body(token(machine, [basic]))["error"] == "invalid_dpop_proof"
    end

    @tag auth: [dpop: false]
    test "a server without DPoP cannot serve such a client", %{config: config} do
      {client, basic} = confidential(config, %{dpop_bound_access_tokens: true})
      {key, _} = Keys.key()
      conn = token(code_params(config, client), [basic, proof_for(key)])
      assert conn.status == 400
      assert body(conn)["error"] == "invalid_client"
    end
  end
end
