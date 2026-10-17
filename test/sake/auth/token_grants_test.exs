defmodule Sake.Auth.TokenGrantsTest do
  # The token endpoint's grants, without HTTP: parameters, the client's
  # credentials (the `Authorization` header's values) and the checked
  # DPoP proof go in; the token response, or a status and an error, come
  # out.
  use SakeTest.AuthCase, async: false

  alias Sake.Auth.{Authorize, Clients, DPoP, JWT, TokenGrants, Tokens}
  alias SakeTest.Keys

  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @resource "http://www.example.com/mcp"
  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @idp "https://idp.example"

  defp code(config, client, scopes \\ ["issues:read"]) do
    Authorize.issue_code(
      config,
      %{
        client_id: client.id,
        redirect_uri: hd(client.redirect_uris),
        code_challenge: @challenge,
        scopes: scopes,
        resource: @resource
      },
      "u1"
    )
  end

  defp code_params(client, code, extra \\ %{}) do
    Map.merge(
      %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "code" => code,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => @verifier
      },
      extra
    )
  end

  defp basic(id, secret), do: ["Basic " <> Base.encode64(id <> ":" <> secret)]

  defp confidential(config, grant_types) do
    {:ok, client, secret} =
      Clients.create(config, %{
        name: "Service",
        redirect_uris: ["https://app.example/cb"],
        confidential: true,
        grant_types: grant_types
      })

    {client, basic(client.id, secret)}
  end

  describe "supported/2" do
    test "names a missing or unsupported grant type before anything else", %{config: config} do
      assert TokenGrants.supported(config, %{"grant_type" => "authorization_code"}) == :ok
      assert TokenGrants.supported(config, %{"grant_type" => "client_credentials"}) == :ok

      assert {:error, 400, "invalid_request", "grant_type is required"} =
               TokenGrants.supported(config, %{})

      assert {:error, 400, "unsupported_grant_type", "Supported grant types: " <> list} =
               TokenGrants.supported(config, %{"grant_type" => "password"})

      assert list == "authorization_code, refresh_token, client_credentials"

      # exchange/4 refuses the same way, before authenticating anyone.
      assert {:error, 400, "unsupported_grant_type", _} =
               TokenGrants.exchange(config, %{"grant_type" => @jwt_bearer}, [], nil)
    end
  end

  describe "client authentication" do
    test "a client that does not authenticate is a 401", %{config: config} do
      {client, _basic} = confidential(config, ["client_credentials"])

      for {params, credentials} <- [
            {%{"grant_type" => "client_credentials", "client_id" => "nope"}, []},
            {%{"grant_type" => "client_credentials"}, basic(client.id, "wrong")},
            {%{"grant_type" => "client_credentials", "client_id" => client.id}, []}
          ] do
        assert {:error, 401, "invalid_client", "Client authentication failed"} =
                 TokenGrants.exchange(config, params, credentials, nil)
      end
    end

    test "a client may use only its own grant types", %{config: config} do
      client = public_client(config, %{grant_types: ["authorization_code"]})

      assert {:error, 400, "unauthorized_client",
              "The client may not use the refresh_token grant"} =
               TokenGrants.exchange(
                 config,
                 %{"grant_type" => "refresh_token", "client_id" => client.id},
                 [],
                 nil
               )
    end
  end

  describe "authorization_code" do
    test "issues a pair for a code, once", %{config: config} do
      client = public_client(config)
      code = code(config, client)

      assert {:ok,
              %{
                "access_token" => access,
                "refresh_token" => _,
                "token_type" => "Bearer",
                "expires_in" => 3600,
                "scope" => "issues:read"
              }} = TokenGrants.exchange(config, code_params(client, code), [], nil)

      {module, state} = Sake.Auth.store(config)
      assert {:ok, %{subject_id: "u1"}} = module.get_token(state, :access, Tokens.hash(access))

      assert {:error, 400, "invalid_grant", "The code is invalid, expired or already used"} =
               TokenGrants.exchange(config, code_params(client, code), [], nil)

      # The reuse revoked what the code issued.
      assert {:ok, %{revoked_at: %DateTime{}}} =
               module.get_token(state, :access, Tokens.hash(access))
    end

    test "checks the code against the request", %{config: config} do
      client = public_client(config)

      for {extra, description} <- [
            {%{"code_verifier" => String.duplicate("a", 43)}, "code_verifier does not match"},
            {%{"redirect_uri" => "http://127.0.0.1:9000/other"}, "redirect_uri does not match"},
            {%{"resource" => "http://www.example.com/acme/mcp"}, "resource does not match"}
          ] do
        params = code_params(client, code(config, client), extra)

        assert {:error, 400, "invalid_grant", ^description} =
                 TokenGrants.exchange(config, params, [], nil)
      end

      assert {:error, 400, "invalid_request", "code, redirect_uri and code_verifier are required"} =
               TokenGrants.exchange(
                 config,
                 Map.delete(code_params(client, "x"), "code_verifier"),
                 [],
                 nil
               )
    end

    test "a checked proof binds the tokens to its key", %{config: config} do
      client = public_client(config)
      {pem, jkt} = Sake.Auth.dpop_key()
      {:ok, key} = JWT.private_key(pem)
      proof = DPoP.proof(key, "POST", "http://www.example.com/oauth/token")

      assert {:ok, checked} = TokenGrants.proof(config, [proof])
      assert checked.jkt == jkt

      assert {:ok, %{"token_type" => "DPoP", "access_token" => access}} =
               TokenGrants.exchange(
                 config,
                 code_params(client, code(config, client)),
                 [],
                 checked
               )

      {module, state} = Sake.Auth.store(config)
      assert {:ok, %{jkt: ^jkt}} = module.get_token(state, :access, Tokens.hash(access))

      # The proof is used up.
      assert {:error, 400, "invalid_dpop_proof", _} =
               TokenGrants.exchange(
                 config,
                 code_params(client, code(config, client)),
                 [],
                 checked
               )
    end
  end

  describe "proof/2" do
    test "no header is no proof; a proof for another URL or several are refused", %{
      config: config
    } do
      {pem, _jkt} = Sake.Auth.dpop_key()
      {:ok, key} = JWT.private_key(pem)

      assert {:ok, nil} = TokenGrants.proof(config, [])

      assert {:error, "invalid_dpop_proof", "The proof's htu does not match the request"} =
               TokenGrants.proof(config, [DPoP.proof(key, "POST", "http://elsewhere/token")])

      assert {:error, "invalid_dpop_proof", "Only one DPoP proof is allowed"} =
               TokenGrants.proof(config, ["a", "b"])
    end

    @tag auth: [dpop: false]
    test "a server without DPoP ignores the header", %{config: config} do
      assert {:ok, nil} = TokenGrants.proof(config, ["anything"])
    end

    @tag auth: [dpop: [required: true]]
    test "a server that requires DPoP refuses a grant without a proof", %{config: config} do
      client = public_client(config)

      assert {:error, 400, "invalid_dpop_proof",
              "This server issues DPoP-bound tokens only: send a proof"} =
               TokenGrants.exchange(config, code_params(client, code(config, client)), [], nil)
    end
  end

  describe "refresh_token" do
    test "rotates the pair; a reuse revokes the family", %{config: config} do
      client = public_client(config)

      {:ok, %{"refresh_token" => refresh}} =
        TokenGrants.exchange(config, code_params(client, code(config, client)), [], nil)

      params = %{"grant_type" => "refresh_token", "client_id" => client.id}

      assert {:ok, %{"refresh_token" => rotated, "scope" => "issues:read"}} =
               TokenGrants.exchange(config, Map.put(params, "refresh_token", refresh), [], nil)

      assert {:error, 400, "invalid_grant", "The refresh token was already used"} =
               TokenGrants.exchange(config, Map.put(params, "refresh_token", refresh), [], nil)

      assert {:error, 400, "invalid_grant", "The refresh token is expired or revoked"} =
               TokenGrants.exchange(config, Map.put(params, "refresh_token", rotated), [], nil)

      assert {:error, 400, "invalid_grant", "Unknown refresh token"} =
               TokenGrants.exchange(config, Map.put(params, "refresh_token", "nope"), [], nil)

      assert {:error, 400, "invalid_request", "refresh_token is required"} =
               TokenGrants.exchange(config, params, [], nil)
    end

    test "narrows the scope, never widens it", %{config: config} do
      client = public_client(config)

      {:ok, %{"refresh_token" => refresh}} =
        TokenGrants.exchange(
          config,
          code_params(client, code(config, client, ["issues:read", "issues:write"])),
          [],
          nil
        )

      params = %{
        "grant_type" => "refresh_token",
        "client_id" => client.id,
        "refresh_token" => refresh
      }

      assert {:ok, %{"refresh_token" => refresh, "scope" => "issues:read"}} =
               TokenGrants.exchange(config, Map.put(params, "scope", "issues:read"), [], nil)

      assert {:error, 400, "invalid_scope", "The scope exceeds what was granted"} =
               TokenGrants.exchange(
                 config,
                 %{params | "refresh_token" => refresh} |> Map.put("scope", "issues:write"),
                 [],
                 nil
               )
    end
  end

  describe "client_credentials" do
    test "a confidential client gets an access token alone", %{config: config} do
      {client, credentials} = confidential(config, ["client_credentials"])

      assert {:ok, response} =
               TokenGrants.exchange(
                 config,
                 %{"grant_type" => "client_credentials", "resource" => @resource},
                 credentials,
                 nil
               )

      assert %{"token_type" => "Bearer", "access_token" => access} = response
      refute Map.has_key?(response, "refresh_token")

      {module, state} = Sake.Auth.store(config)
      id = client.id

      assert {:ok, %{subject_id: nil, client_id: ^id}} =
               module.get_token(state, :access, Tokens.hash(access))

      assert {:error, 400, "invalid_target", _} =
               TokenGrants.exchange(
                 config,
                 %{"grant_type" => "client_credentials", "resource" => "https://other/mcp"},
                 credentials,
                 nil
               )

      assert {:error, 400, "invalid_scope", "Unknown scope: nope"} =
               TokenGrants.exchange(
                 config,
                 %{
                   "grant_type" => "client_credentials",
                   "scope" => "nope",
                   "resource" => @resource
                 },
                 credentials,
                 nil
               )
    end

    test "a public client may not use it", %{config: config} do
      # Registration refuses such a client; one already in the store is
      # refused here too.
      client = %{public_client(config) | grant_types: ["client_credentials"]}
      {module, state} = Sake.Auth.store(config)
      :ok = module.put_client(state, client)

      assert {:error, 400, "unauthorized_client",
              "Only a confidential client may use client_credentials"} =
               TokenGrants.exchange(
                 config,
                 %{"grant_type" => "client_credentials", "client_id" => client.id},
                 [],
                 nil
               )
    end
  end

  describe "jwt-bearer" do
    setup %{config: config} do
      {key, jwk} = Keys.key(:ec, "idp-1")
      stop_supervised!(Sake)

      auth = [
        subject: SakeDev.Subject,
        issuer: config.issuer,
        allow_insecure: true,
        servers: [SakeDev.Server],
        resources: ["/mcp", "/:org/mcp"],
        trusted_issuers: [[issuer: @idp, jwks: %{"keys" => [jwk]}, clients: :any]]
      ]

      start_supervised!(
        {Sake,
         auth: auth, secret_key_base: SakeTest.ModernClient.secret(), streams: false, tasks: false}
      )

      %{config: Sake.Auth.config(), key: key}
    end

    defp id_jag(key, client) do
      Keys.sign(
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
        },
        key,
        %{"typ" => "oauth-id-jag+jwt"}
      )
    end

    test "an ID-JAG is exchanged for an access token for its person", %{config: config, key: key} do
      {:ok, client, nil} = Clients.create(config, %{name: "Agent", grant_types: [@jwt_bearer]})
      params = %{"grant_type" => @jwt_bearer, "client_id" => client.id}

      assert {:ok, %{"access_token" => access, "scope" => "issues:read"} = response} =
               TokenGrants.exchange(
                 config,
                 Map.put(params, "assertion", id_jag(key, client)),
                 [],
                 nil
               )

      refute Map.has_key?(response, "refresh_token")
      {module, state} = Sake.Auth.store(config)
      assert {:ok, %{subject_id: "u1"}} = module.get_token(state, :access, Tokens.hash(access))

      assert {:error, 400, "invalid_request", "assertion is required"} =
               TokenGrants.exchange(config, params, [], nil)

      assert {:error, 400, "invalid_grant", _} =
               TokenGrants.exchange(config, Map.put(params, "assertion", "junk"), [], nil)
    end
  end
end
