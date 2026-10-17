defmodule Sake.Auth.PARTest do
  # Pushed authorization requests (RFC 9126): the push, the authorize
  # endpoint taking it, the requirement, and the DPoP key binding the
  # push records (RFC 9449 §10).
  use SakeTest.AuthCase, async: false
  import Plug.Test
  import Plug.Conn, except: [push: 2]

  alias Sake.Auth.{Authorize, DPoP, JWT, Metadata, PAR, PushedRequest, Tokens}
  alias SakeTest.Keys

  @moduletag auth: [par: true]

  @par_url "http://www.example.com/oauth/par"
  @token_url "http://www.example.com/oauth/token"
  @resource "http://www.example.com/mcp"
  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @prefix "urn:ietf:params:oauth:request_uri:"

  defp params(client, extra \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "code_challenge" => @challenge,
        "code_challenge_method" => "S256",
        "state" => "xyz",
        "scope" => "issues:read",
        "resource" => @resource
      },
      extra
    )
  end

  defp form(path, params, headers) do
    conn =
      conn(:post, path, URI.encode_query(params))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  defp push(params, headers \\ []),
    do: Sake.Auth.RouterPlug.call(form("/par", params, headers), Sake.Auth.RouterPlug.init([]))

  defp token(params, headers \\ []),
    do: Sake.Auth.Token.call(form("/oauth/token", params, headers), Sake.Auth.Token.init([]))

  defp authorize(query, user \\ "u1") do
    conn(:get, "/oauth/authorize", query)
    |> then(
      &if(user, do: init_test_session(&1, %{user_id: user}), else: init_test_session(&1, %{}))
    )
    |> Authorize.call(Authorize.init([]))
  end

  defp decide(request, decision, user \\ "u1") do
    conn(:post, "/oauth/authorize", %{"decision" => decision, "request" => request})
    |> init_test_session(%{user_id: user})
    |> Authorize.call(Authorize.init([]))
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  defp form_request(conn) do
    [_, request] = Regex.run(~r/name="request" value="([^"]+)"/, conn.resp_body)
    request
  end

  defp location(conn) do
    [location] = get_resp_header(conn, "location")
    uri = URI.parse(location)
    {"#{uri.scheme}://#{uri.authority}#{uri.path}", URI.decode_query(uri.query || "")}
  end

  defp pushed(client, extra \\ %{}, headers \\ []) do
    conn = push(params(client, extra), headers)
    assert conn.status == 201, conn.resp_body
    %{"request_uri" => request_uri} = body(conn)
    request_uri
  end

  # The code a pushed request ends in: the consent page approved, or at
  # once once the consent is remembered.
  defp code(client, request_uri),
    do: approved(authorize(%{"client_id" => client.id, "request_uri" => request_uri}))

  defp approved(%{status: 200} = conn), do: approved(decide(form_request(conn), "approve"))

  defp approved(%{status: 302} = conn) do
    {_uri, %{"code" => code}} = location(conn)
    code
  end

  defp code_params(client, code) do
    %{
      "grant_type" => "authorization_code",
      "code" => code,
      "client_id" => client.id,
      "redirect_uri" => hd(client.redirect_uris),
      "code_verifier" => @verifier
    }
  end

  defp confidential(config, attrs \\ %{}) do
    {:ok, client, secret} =
      Sake.Auth.Clients.create(
        config,
        Map.merge(
          %{name: "Web", redirect_uris: ["https://app.example/cb"], confidential: true},
          attrs
        )
      )

    {client, {"authorization", "Basic " <> Base.encode64(client.id <> ":" <> secret)}}
  end

  describe "the push" do
    test "a public client pushes a request and gets a request_uri for 60 seconds", %{
      config: config
    } do
      client = public_client(config)
      conn = push(params(client))

      assert conn.status == 201
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert %{"request_uri" => @prefix <> random, "expires_in" => 60} = body(conn)
      assert {:ok, <<_::binary-size(32)>>} = Base.url_decode64(random, padding: false)

      # Stored by its hash, never as it is.
      {mod, state} = Sake.Auth.store(config)

      assert {:ok, %PushedRequest{client_id: id, state: "xyz", scopes: ["issues:read"]}} =
               mod.consume_pushed_request(state, Tokens.hash(@prefix <> random))

      assert id == client.id
    end

    test "a confidential client authenticates as at the token endpoint", %{config: config} do
      {client, basic} = confidential(config)
      params = Map.delete(params(client), "client_id")
      assert push(params, [basic]).status == 201

      bad = {"authorization", "Basic " <> Base.encode64(client.id <> ":wrong")}
      conn = push(params, [bad])
      assert conn.status == 401
      assert %{"error" => "invalid_client"} = body(conn)
      assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="sake")]

      # Its secret, not its client_id alone.
      assert push(params(client)).status == 401

      # A client_id that names another client than the one authenticated.
      conn = push(Map.put(params, "client_id", "someone-else"), [basic])
      assert %{"error" => "invalid_request", "error_description" => description} = body(conn)
      assert description =~ "client_id"
    end

    test "a push is validated as an authorization request", %{config: config} do
      client = public_client(config)

      for {extra, error, why} <- [
            {%{"request_uri" => @prefix <> "x"}, "invalid_request", "request_uri"},
            {%{"request" => "eyJ.eyJ.sig"}, "request_not_supported", "Request objects"},
            {%{"redirect_uri" => "http://127.0.0.1:9000/other"}, "invalid_request",
             "redirect_uri"},
            {%{"code_challenge" => nil}, "invalid_request", "code_challenge"},
            {%{"response_type" => "token"}, "unsupported_response_type", "response_type"},
            {%{"scope" => "nope"}, "invalid_scope", "nope"},
            {%{"resource" => "https://elsewhere.example/mcp"}, "invalid_target", "resource"},
            {%{"dpop_jkt" => "short"}, "invalid_request", "dpop_jkt"}
          ] do
        conn = push(Map.reject(params(client, extra), fn {_, v} -> is_nil(v) end))
        assert conn.status == 400, why
        assert %{"error" => ^error, "error_description" => description} = body(conn)
        assert description =~ why
      end
    end

    test "an unknown client is invalid_client, and GET is not allowed", %{config: config} do
      client = public_client(config)
      assert push(params(client, %{"client_id" => "nope"})).status == 401

      conn = conn(:get, "/par") |> Sake.Auth.PushedAuthorization.call([])
      assert conn.status == 405
    end
  end

  describe "the authorize endpoint" do
    test "takes the pushed request, ignoring every other parameter", %{config: config} do
      client = public_client(config)
      request_uri = pushed(client)

      conn =
        authorize(%{
          "client_id" => client.id,
          "request_uri" => request_uri,
          "state" => "evil",
          "scope" => "issues:read issues:write",
          "redirect_uri" => "https://evil.example/cb"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Read issues"
      refute conn.resp_body =~ "issues:write"

      conn = decide(form_request(conn), "approve")

      assert {"http://127.0.0.1:9000/callback", %{"code" => code, "state" => "xyz"}} =
               location(conn)

      assert %{"token_type" => "Bearer", "scope" => "issues:read"} =
               body(token(code_params(client, code)))
    end

    test "a request_uri is good once; the consent form needs it no more", %{config: config} do
      client = public_client(config)
      request_uri = pushed(client)
      query = %{"client_id" => client.id, "request_uri" => request_uri}

      first = authorize(query)
      assert first.status == 200

      # A reload of the page: the request was taken.
      again = authorize(query)
      assert again.status == 400
      assert again.resp_body =~ "no longer valid"
      assert get_resp_header(again, "location") == []

      # The form still works: it carries the request itself, and a denial
      # goes to the pushed redirect URI with the pushed state.
      assert {"http://127.0.0.1:9000/callback", %{"error" => "access_denied", "state" => "xyz"}} =
               location(decide(form_request(first), "deny"))
    end

    test "an expired request_uri is refused", %{config: config} do
      client = public_client(config)
      {mod, state} = Sake.Auth.store(config)
      request_uri = @prefix <> Tokens.generate()
      past = DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)

      :ok =
        mod.put_pushed_request(state, %PushedRequest{
          hash: Tokens.hash(request_uri),
          client_id: client.id,
          redirect_uri: hd(client.redirect_uris),
          state: "xyz",
          code_challenge: @challenge,
          scopes: ["issues:read"],
          resource: @resource,
          expires_at: past,
          inserted_at: DateTime.add(past, -60)
        })

      conn = authorize(%{"client_id" => client.id, "request_uri" => request_uri})
      assert conn.status == 400 and conn.resp_body =~ "no longer valid"
      assert get_resp_header(conn, "location") == []
    end

    @tag auth: [par: [expires_in: 120]]
    test "par: [expires_in:] sets how long a request_uri lasts", %{config: config} do
      assert %{"expires_in" => 120} = body(push(params(public_client(config))))
    end

    test "another client's request_uri, or an unknown one, renders an error page", %{
      config: config
    } do
      client = public_client(config)
      other = public_client(config, %{name: "Other"})
      request_uri = pushed(client)

      for query <- [
            %{"client_id" => other.id, "request_uri" => request_uri},
            %{"client_id" => client.id, "request_uri" => request_uri},
            %{"request_uri" => pushed(client)},
            %{"client_id" => client.id, "request_uri" => @prefix <> "unknown"},
            %{"client_id" => client.id, "request_uri" => "https://elsewhere.example/r"}
          ] do
        conn = authorize(query)
        assert conn.status == 400 and conn.resp_body =~ "no longer valid", inspect(query)
        assert get_resp_header(conn, "location") == []
      end
    end

    test "a person not signed in is asked to, and the request_uri is not spent", %{
      config: config
    } do
      client = public_client(config)
      query = %{"client_id" => client.id, "request_uri" => pushed(client)}

      conn = authorize(query, nil)
      assert conn.status == 401 and conn.resp_body =~ "Sign in"
      assert authorize(query).status == 200
    end

    test "a remembered consent issues the code at once", %{config: config} do
      client = public_client(config)
      code(client, pushed(client))

      conn = authorize(%{"client_id" => client.id, "request_uri" => pushed(client)})
      assert {"http://127.0.0.1:9000/callback", %{"code" => _, "state" => "xyz"}} = location(conn)
    end

    test "a direct request still works while pushing is not required", %{config: config} do
      client = public_client(config)
      assert authorize(params(client)).status == 200
    end
  end

  describe "the requirement" do
    @describetag auth: [par: [required: true]]

    test "par: [required: true] refuses a request that was not pushed", %{config: config} do
      client = public_client(config)

      assert {"http://127.0.0.1:9000/callback",
              %{
                "error" => "invalid_request",
                "error_description" => description,
                "state" => "xyz"
              }} =
               location(authorize(params(client)))

      assert description =~ "pushed authorization requests are required"
      assert authorize(%{"client_id" => client.id, "request_uri" => pushed(client)}).status == 200
    end

    @tag auth: [par: true]
    test "a client registered with require_pushed_authorization_requests", %{config: config} do
      strict = public_client(config, %{require_pushed_authorization_requests: true})
      lenient = public_client(config)

      assert {_, %{"error" => "invalid_request"}} = location(authorize(params(strict)))
      assert authorize(params(lenient)).status == 200
      assert authorize(%{"client_id" => strict.id, "request_uri" => pushed(strict)}).status == 200
    end

    @tag auth: [par: false]
    test "without par:, a client's require_pushed_authorization_requests is not enforced", %{
      config: config
    } do
      strict = public_client(config, %{require_pushed_authorization_requests: true})
      assert authorize(params(strict)).status == 200
    end
  end

  describe "the DPoP key binding" do
    test "a push with a proof binds the code to the proof's key", %{config: config} do
      client = public_client(config)
      {key, jwk} = Keys.key()
      {other, _} = Keys.key()
      jkt = JWT.thumbprint(jwk)
      proof = {"dpop", DPoP.proof(key, "POST", @par_url)}
      request_uri = pushed(client, %{}, [proof])

      {mod, state} = Sake.Auth.store(config)
      code = code(client, request_uri)
      params = code_params(client, code)

      # Without a proof, or with another key, the code is refused (and
      # spent, as on a wrong code_verifier).
      assert %{"error" => "invalid_grant", "error_description" => description} =
               body(token(params))

      assert description =~ "bound to a DPoP key"

      code = code(client, pushed(client, %{}, [{"dpop", DPoP.proof(key, "POST", @par_url)}]))
      params = code_params(client, code)
      other_proof = {"dpop", DPoP.proof(other, "POST", @token_url)}

      assert %{"error" => "invalid_grant", "error_description" => description} =
               body(token(params, [other_proof]))

      assert description =~ "another DPoP key"

      code = code(client, pushed(client, %{}, [{"dpop", DPoP.proof(key, "POST", @par_url)}]))
      own = {"dpop", DPoP.proof(key, "POST", @token_url)}

      assert %{"token_type" => "DPoP", "access_token" => access} =
               body(token(code_params(client, code), [own]))

      assert {:ok, %{jkt: ^jkt}} = mod.get_token(state, :access, Tokens.hash(access))
    end

    test "a proof made for another endpoint, or used twice, is refused", %{config: config} do
      client = public_client(config)
      {key, _jwk} = Keys.key()

      conn = push(params(client), [{"dpop", DPoP.proof(key, "POST", @token_url)}])
      assert conn.status == 400
      assert %{"error" => "invalid_dpop_proof"} = body(conn)

      proof = {"dpop", DPoP.proof(key, "POST", @par_url)}
      assert push(params(client), [proof]).status == 201
      assert %{"error" => "invalid_dpop_proof"} = body(push(params(client), [proof]))
    end

    test "dpop_jkt binds the code, pushed or sent directly, and must match a proof", %{
      config: config
    } do
      client = public_client(config)
      {key, jwk} = Keys.key()
      {_other, other_jwk} = Keys.key()
      jkt = JWT.thumbprint(jwk)

      # Pushed with dpop_jkt alone.
      code = code(client, pushed(client, %{"dpop_jkt" => jkt}))
      assert %{"error" => "invalid_grant"} = body(token(code_params(client, code)))

      # Sent directly, with dpop_jkt (RFC 9449 §10).
      code = approved(authorize(params(client, %{"dpop_jkt" => jkt})))
      own = {"dpop", DPoP.proof(key, "POST", @token_url)}
      assert %{"token_type" => "DPoP"} = body(token(code_params(client, code), [own]))

      # A push whose dpop_jkt is not its proof's key.
      conn =
        push(params(client, %{"dpop_jkt" => JWT.thumbprint(other_jwk)}), [
          {"dpop", DPoP.proof(key, "POST", @par_url)}
        ])

      assert %{"error" => "invalid_dpop_proof"} = body(conn)

      # The same key both ways is fine.
      assert push(params(client, %{"dpop_jkt" => jkt}), [
               {"dpop", DPoP.proof(key, "POST", @par_url)}
             ]).status == 201
    end

    @tag auth: [par: true, dpop: false]
    test "without DPoP, the proof and dpop_jkt are ignored", %{config: config} do
      client = public_client(config)
      {key, jwk} = Keys.key()

      request_uri =
        pushed(client, %{"dpop_jkt" => JWT.thumbprint(jwk)}, [
          {"dpop", DPoP.proof(key, "POST", @par_url)}
        ])

      code = code(client, request_uri)
      assert %{"token_type" => "Bearer"} = body(token(code_params(client, code)))
    end

    @tag auth: [par: true, dpop: [nonce: true]]
    test "a server that wants nonces asks for one at the push", %{config: config} do
      client = public_client(config)
      {key, _jwk} = Keys.key()

      conn = push(params(client), [{"dpop", DPoP.proof(key, "POST", @par_url)}])
      assert %{"error" => "use_dpop_nonce"} = body(conn)
      [nonce] = get_resp_header(conn, "dpop-nonce")

      conn = push(params(client), [{"dpop", DPoP.proof(key, "POST", @par_url, nonce: nonce)}])
      assert conn.status == 201
      assert [_] = get_resp_header(conn, "dpop-nonce")
    end
  end

  describe "registration and metadata" do
    defp register(doc) do
      conn(:post, "/oauth/register", JSON.encode!(doc))
      |> put_req_header("content-type", "application/json")
      |> Sake.Auth.DCR.call(Sake.Auth.DCR.init([]))
    end

    @doc_base %{"redirect_uris" => ["http://127.0.0.1:9000/callback"], "client_name" => "CLI"}

    test "dynamic registration keeps require_pushed_authorization_requests", %{config: config} do
      assert register(Map.put(@doc_base, "require_pushed_authorization_requests", "yes")).status ==
               400

      conn = register(Map.put(@doc_base, "require_pushed_authorization_requests", true))
      assert %{"client_id" => id, "require_pushed_authorization_requests" => true} = body(conn)
      {:ok, client} = Sake.Auth.Clients.get(config, id)
      assert client.require_pushed_authorization_requests

      assert %{"require_pushed_authorization_requests" => false} = body(register(@doc_base))
    end

    @tag auth: [par: false]
    test "without par:, registration says nothing of it" do
      conn = register(Map.put(@doc_base, "require_pushed_authorization_requests", "yes"))
      assert conn.status == 201
      refute Map.has_key?(body(conn), "require_pushed_authorization_requests")
    end

    test "the metadata lists the endpoint", %{config: config} do
      m = Metadata.authorization_server(config)
      assert m["pushed_authorization_request_endpoint"] == @par_url
      assert m["require_pushed_authorization_requests"] == false
    end

    @tag auth: [par: [required: true]]
    test "the metadata says when pushing is required", %{config: config} do
      assert Metadata.authorization_server(config)["require_pushed_authorization_requests"]
    end

    @tag auth: [par: false]
    test "without par:, nothing changes", %{config: config} do
      m = Metadata.authorization_server(config)
      refute Map.has_key?(m, "pushed_authorization_request_endpoint")
      refute Map.has_key?(m, "require_pushed_authorization_requests")

      client = public_client(config)
      assert push(params(client)).status == 404

      # A request_uri is a parameter like any unknown one: the request
      # goes on as it was sent.
      assert authorize(params(client, %{"request_uri" => @prefix <> "x"})).status == 200
    end
  end

  test "par: takes true, false or [required:, expires_in:]" do
    for bad <- [:yes, [required: :sometimes], [expires_in: 0], [other: 1]] do
      assert_raise ArgumentError, ~r/par:/, fn ->
        Sake.Auth.Config.new(
          subject: SakeDev.Subject,
          issuer: "http://www.example.com",
          allow_insecure: true,
          par: bad
        )
      end
    end
  end

  test "the core binds a push to its proof's key", %{config: config} do
    client = public_client(config)
    jkt = "0ZcOCORZNYy-DWpqq30jZyJGHTN0d2HglBV3uiguA4I"
    assert {:ok, %{"request_uri" => request_uri}} = PAR.push(config, client, params(client), jkt)
    assert {:ok, ^client, request} = PAR.take(config, client.id, request_uri)
    assert request.extra == %{"dpop_jkt" => jkt}
    assert {:error, :request_uri} = PAR.take(config, client.id, request_uri)
  end
end
