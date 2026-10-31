defmodule SakeTest.FakeOAuth do
  @moduledoc false
  # A protected MCP endpoint at /mcp and its authorization server, on one
  # origin, in the spirit of the conformance suite's fixtures: a modern
  # server that knows `server/discover`, `tools/list` and `tools/call`, and
  # an authorization server that approves every request at once. Every
  # request is sent to the test process as `{:fake_oauth, method, path,
  # params, headers}`; the options change how it answers:
  #
  #   * `:prm` — `:path` (the default), `:root`, `:none`, or a document map
  #     to serve at the path-inserted URL as is.
  #   * `:in_header` — whether the 401 names the metadata URL (default true).
  #   * `:challenge_scope` — the 401's `scope`, if any.
  #   * `:scopes_supported` — the resource metadata's, if any.
  #   * `:resource_metadata` — fields merged into the resource metadata.
  #   * `:issuer_path` — the authorization server's path ("" by default).
  #   * `:metadata_at` — where its metadata is served, by default the RFC 8414
  #     path-inserted URL.
  #   * `:metadata` — fields merged into its metadata (`nil` removes one).
  #   * `:iss` — `:correct` (default), `:trailing_slash`, `:omit`, or a
  #     string to send.
  #   * `:call_scopes` — the scopes `tools/call` needs (a 403 otherwise);
  #     with `:deny_calls`, every call is refused with them anyway.
  #   * `:legacy` — answer as a 2025-06-18 server instead.
  #   * `:tool_pages` — `tools/list` answers in that many pages, one tool
  #     (`t1`, `t2`, ...) each, the cursor being the next page's number.
  #   * `:grant` — the scopes every token gets, whatever was asked for.
  #   * `:expires_in`, `:refresh` (default true) — the token answers.
  #   * `:token_type` — the `token_type` they give (default "Bearer").
  #   * `:registration` — fields merged into the registration answer.
  #   * `:grant_error` — an error code every client credentials or JWT
  #     bearer request is answered with.
  #   * `:idp_error` — an error code the identity provider's token
  #     exchange (at /idp/token, metadata at the RFC 8414 URL of the
  #     issuer `/idp`) answers with; otherwise it returns `jag-` and the
  #     subject token as the ID-JAG. A SAML assertion (subject token type
  #     `saml2`) gets a refresh token `idp-refresh-<n>`, in the
  #     `refresh_token` member (or `access_token` with `saml_in:
  #     :access_token`), good for `:idp_refresh_expires_in` seconds when
  #     given; that refresh token then gets `jag-` and the assertion it
  #     came from, until the test deletes it from the state's
  #     `:idp_refresh`.
  #   * `:idp_auth_methods` — the identity provider's
  #     `token_endpoint_auth_methods_supported` (default
  #     `["client_secret_post"]`).
  #   * `:hmac_secret` — the client secret a client_secret_jwt assertion
  #     is checked against, at both token endpoints: HS256, the client as
  #     `iss` and `sub`, the issuer or the endpoint (or the literal
  #     `urn:test:audience`) as `aud`, a `jti`, and an unexpired `exp`. Any other assertion is `invalid_client`.
  #   * `:jwt` — a private key: access tokens are then JWTs (RFC 9068)
  #     signed with it (`kid` "fake-1"), for the resource the client named,
  #     with the client as `client_id` and as `sub` for a grant without a
  #     person (`fake-user` otherwise), and its JWK Set is served at
  #     `<issuer>/jwks` (the metadata's `jwks_uri`), from the state's
  #     `:jwks` when a test puts one there. `:jwt_typ` is their `typ`
  #     (default "at+jwt"), `:jwt_claims` merged into their claims.
  #   * `:introspection` — `{client_id, secret}`: an introspection
  #     endpoint (RFC 7662) at `<issuer>/introspect`, for that client with
  #     HTTP Basic, answers with the claims of the tokens it issued, and
  #     `active: false` for any other or one in the state's `:revoked`.
  #   * `:dpop` — the metadata offers DPoP, and a token request with a
  #     DPoP proof gets a DPoP-bound token (`cnf.jkt`). Without it a proof
  #     is ignored.
  #   * `:state` — the Agent with the issued codes and tokens (required).

  @behaviour Plug
  import Plug.Conn

  alias Sake.Client.Auth.Grant

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(conn, opts) do
    conn = fetch_query_params(conn)
    {:ok, body, conn} = read_body(conn)
    params = Map.merge(conn.query_params, decode(conn, body))
    send(opts.test, {:fake_oauth, conn.method, conn.request_path, params, conn.req_headers})
    route(conn, conn.method, conn.request_path, params, opts)
  end

  defp decode(conn, body) do
    case get_req_header(conn, "content-type") do
      ["application/json" <> _] -> JSON.decode!(body)
      ["application/x-www-form-urlencoded" <> _] -> URI.decode_query(body)
      _ -> %{}
    end
  end

  # ---- the MCP endpoint

  defp route(conn, "POST", "/mcp", message, opts) do
    case token_scopes(conn, opts) do
      nil ->
        conn
        |> put_resp_header("www-authenticate", challenge(conn, opts))
        |> send_resp(401, "")

      scopes ->
        mcp(conn, message, scopes, opts)
    end
  end

  defp route(conn, "GET", path, _params, opts) do
    cond do
      path == "/.well-known/oauth-authorization-server/idp" ->
        json(conn, 200, idp_metadata(conn, opts))

      opts[:jwt] && path == issuer_path(opts) <> "/jwks" ->
        json(conn, 200, jwks(opts))

      resource_metadata?(path, opts) ->
        resource_metadata(conn, opts)

      path == metadata_path(opts) ->
        json(conn, 200, metadata(conn, opts))

      path == issuer_path(opts) <> "/authorize" ->
        authorize(conn, opts)

      true ->
        send_resp(conn, 404, "")
    end
  end

  defp route(conn, "POST", path, params, opts) do
    cond do
      path == "/idp/token" -> token_exchange(conn, params, opts)
      path == issuer_path(opts) <> "/introspect" -> introspect(conn, params, opts)
      path == issuer_path(opts) <> "/token" -> token(conn, params, opts)
      path == issuer_path(opts) <> "/register" -> register(conn, params, opts)
      true -> send_resp(conn, 404, "")
    end
  end

  defp token_scopes(conn, opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Agent.get(opts.state, &get_in(&1, [:tokens, token]))
      _ -> nil
    end
  end

  defp challenge(conn, opts) do
    params =
      if(Map.get(opts, :in_header, true),
        do: [~s(resource_metadata="#{base(conn)}/.well-known/oauth-protected-resource/mcp")],
        else: []
      ) ++
        if opts[:challenge_scope], do: [~s(scope="#{opts.challenge_scope}")], else: []

    "Bearer " <> Enum.join(params, ", ")
  end

  defp mcp(conn, %{"method" => "notifications/" <> _}, _scopes, _opts),
    do: send_resp(conn, 202, "")

  defp mcp(conn, %{"id" => id, "method" => method} = message, scopes, opts) do
    case answer(method, message, scopes, opts) do
      {:forbidden, needed} ->
        conn
        |> put_resp_header(
          "www-authenticate",
          ~s(Bearer error="insufficient_scope", scope="#{Enum.join(needed, " ")}", resource_metadata="#{base(conn)}/.well-known/oauth-protected-resource/mcp")
        )
        |> send_resp(403, "")

      {key, value} ->
        json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, key => value})
    end
  end

  defp answer("server/discover", _message, _scopes, %{legacy: true}),
    do: {"error", %{"code" => -32_601, "message" => "Method not found"}}

  defp answer("initialize", _message, _scopes, %{legacy: true}) do
    {"result",
     %{
       "protocolVersion" => "2025-06-18",
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "L", "version" => "1"}
     }}
  end

  defp answer("server/discover", _message, _scopes, _opts) do
    {"result",
     %{
       "resultType" => "complete",
       "supportedVersions" => ["2026-07-28"],
       "capabilities" => %{"tools" => %{}}
     }}
  end

  defp answer("tools/call", message, scopes, opts) do
    needed = opts[:call_scopes] || []

    if needed -- scopes != [] or opts[:deny_calls] == true,
      do: {:forbidden, needed},
      else: {"result", %{"content" => [%{"type" => "text", "text" => message["params"]["name"]}]}}
  end

  defp answer("tools/list", message, _scopes, %{tool_pages: pages}) do
    n = String.to_integer(get_in(message, ["params", "cursor"]) || "1")
    page = %{"tools" => [%{"name" => "t#{n}", "inputSchema" => %{"type" => "object"}}]}
    {"result", if(n < pages, do: Map.put(page, "nextCursor", "#{n + 1}"), else: page)}
  end

  defp answer(_method, _message, _scopes, _opts), do: {"result", %{"tools" => []}}

  # ---- metadata

  defp resource_metadata?(path, opts) do
    case Map.get(opts, :prm, :path) do
      :root -> path == "/.well-known/oauth-protected-resource"
      :none -> false
      _path_or_doc -> path == "/.well-known/oauth-protected-resource/mcp"
    end
  end

  defp resource_metadata(conn, %{prm: doc}) when is_map(doc), do: json(conn, 200, doc)

  defp resource_metadata(conn, opts) do
    resource = if opts[:prm] == :root, do: base(conn), else: base(conn) <> "/mcp"

    doc =
      %{"resource" => resource, "authorization_servers" => [base(conn) <> issuer_path(opts)]}
      |> put_present("scopes_supported", opts[:scopes_supported])
      |> Map.merge(opts[:resource_metadata] || %{})

    json(conn, 200, doc)
  end

  defp issuer_path(opts), do: opts[:issuer_path] || ""

  defp metadata_path(opts),
    do: opts[:metadata_at] || "/.well-known/oauth-authorization-server" <> issuer_path(opts)

  defp metadata(conn, opts) do
    issuer = base(conn) <> issuer_path(opts)

    %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> "/authorize",
      "token_endpoint" => issuer <> "/token",
      "registration_endpoint" => issuer <> "/register",
      "response_types_supported" => ["code"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none"]
    }
    |> put_present("jwks_uri", if(opts[:jwt], do: issuer <> "/jwks"))
    |> put_present(
      "introspection_endpoint",
      if(opts[:introspection], do: issuer <> "/introspect")
    )
    |> put_present("dpop_signing_alg_values_supported", if(opts[:dpop], do: ["ES256"]))
    |> Map.merge(opts[:metadata] || %{})
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  # ---- the authorization server

  defp authorize(conn, opts) do
    p = conn.query_params
    code = "code-" <> Integer.to_string(System.unique_integer([:positive]))
    Agent.update(opts.state, &put_in(&1, [:codes, code], p))

    iss =
      case Map.get(opts, :iss, :correct) do
        :correct -> base(conn) <> issuer_path(opts)
        :trailing_slash -> base(conn) <> issuer_path(opts) <> "/"
        :omit -> nil
        value -> value
      end

    query =
      %{"code" => code, "state" => p["state"], "iss" => iss}
      |> Map.reject(fn {_, v} -> is_nil(v) end)
      |> URI.encode_query()

    conn
    |> put_resp_header("location", p["redirect_uri"] <> "?" <> query)
    |> send_resp(302, "")
  end

  defp token(conn, %{"client_assertion" => jwt} = p, %{hmac_secret: _} = opts)
       when not is_map_key(opts, :assertion_checked) do
    issuer = base(conn) <> issuer_path(opts)

    if hmac_ok?(jwt, opts.hmac_secret, [issuer, issuer <> "/token", "urn:test:audience"]),
      do: token(conn, p, Map.put(opts, :assertion_checked, true)),
      else: json(conn, 401, %{"error" => "invalid_client"})
  end

  defp token(conn, %{"grant_type" => "authorization_code"} = p, opts) do
    request = Agent.get(opts.state, &get_in(&1, [:codes, p["code"]]))

    if request &&
         Grant.challenge(p["code_verifier"] || "") == request["code_challenge"],
       do: issue(conn, opts[:grant] || String.split(request["scope"] || ""), opts, p),
       else: json(conn, 400, %{"error" => "invalid_grant"})
  end

  defp token(conn, %{"grant_type" => "refresh_token"} = p, opts) do
    case Agent.get(opts.state, &get_in(&1, [:refresh, p["refresh_token"]])) do
      nil -> json(conn, 400, %{"error" => "invalid_grant"})
      scopes -> issue(conn, scopes, opts)
    end
  end

  defp token(conn, %{"grant_type" => grant} = p, opts)
       when grant in ["client_credentials", "urn:ietf:params:oauth:grant-type:jwt-bearer"] do
    case opts[:grant_error] do
      nil ->
        issue(
          conn,
          opts[:grant] || String.split(p["scope"] || ""),
          Map.put(opts, :refresh, false),
          Map.put(p, "machine", true)
        )

      error ->
        json(conn, 400, %{"error" => error})
    end
  end

  # ---- the enterprise identity provider

  defp idp_metadata(conn, opts) do
    %{
      "issuer" => base(conn) <> "/idp",
      "token_endpoint" => base(conn) <> "/idp/token",
      "token_endpoint_auth_methods_supported" => opts[:idp_auth_methods] || ["client_secret_post"]
    }
  end

  defp token_exchange(conn, %{"client_assertion" => jwt} = p, %{hmac_secret: secret} = opts)
       when not is_map_key(opts, :assertion_checked) do
    audiences = [base(conn) <> "/idp", base(conn) <> "/idp/token", "urn:test:audience"]

    if hmac_ok?(jwt, secret, audiences),
      do: token_exchange(conn, p, Map.put(opts, :assertion_checked, true)),
      else: json(conn, 401, %{"error" => "invalid_client"})
  end

  defp token_exchange(conn, p, opts) do
    cond do
      opts[:idp_error] ->
        json(conn, 400, %{"error" => opts.idp_error})

      p["subject_token_type"] == "urn:ietf:params:oauth:token-type:saml2" ->
        saml_exchange(conn, p["subject_token"], opts)

      p["subject_token_type"] == "urn:ietf:params:oauth:token-type:refresh_token" ->
        case Agent.get(opts.state, &get_in(&1, [:idp_refresh, p["subject_token"]])) do
          nil -> json(conn, 400, %{"error" => "invalid_grant"})
          assertion -> id_jag(conn, assertion)
        end

      true ->
        id_jag(conn, p["subject_token"])
    end
  end

  defp id_jag(conn, subject) do
    json(conn, 200, %{
      "access_token" => "jag-" <> subject,
      "issued_token_type" => "urn:ietf:params:oauth:token-type:id-jag",
      "token_type" => "N_A"
    })
  end

  defp saml_exchange(conn, assertion, opts) do
    refresh = "idp-refresh-" <> Integer.to_string(System.unique_integer([:positive]))
    Agent.update(opts.state, &put_in(&1, [:idp_refresh, refresh], assertion))

    body =
      case opts[:saml_in] do
        :access_token -> %{"access_token" => refresh}
        _ -> %{"access_token" => "N_A", "refresh_token" => refresh}
      end

    json(
      conn,
      200,
      body
      |> Map.merge(%{
        "issued_token_type" => "urn:ietf:params:oauth:token-type:refresh_token",
        "token_type" => "N_A"
      })
      |> put_present("expires_in", opts[:idp_refresh_expires_in])
    )
  end

  # A client_secret_jwt assertion (RFC 7523 §2.2, HS256), checked the
  # way an identity provider or authorization server that takes them
  # would.
  defp hmac_ok?(jwt, secret, audiences) do
    with [h, c, mac] <- String.split(jwt, "."),
         {:ok, header} <- Base.url_decode64(h, padding: false),
         %{"alg" => "HS256"} <- JSON.decode!(header),
         expected = :crypto.mac(:hmac, :sha256, secret, h <> "." <> c),
         {:ok, ^expected} <- Base.url_decode64(mac, padding: false),
         {:ok, json} <- Base.url_decode64(c, padding: false),
         %{"iss" => iss, "sub" => iss, "aud" => aud, "jti" => jti, "exp" => exp}
         when is_binary(jti) <- JSON.decode!(json) do
      aud in audiences and exp > System.system_time(:second)
    else
      _ -> false
    end
  end

  defp issue(conn, scopes, opts, p \\ %{}) do
    n = Integer.to_string(System.unique_integer([:positive]))
    jkt = bound_key(conn, opts)
    claims = claims(conn, scopes, opts, p, jkt)
    access = if opts[:jwt], do: signed(claims, opts), else: "access-" <> n
    refresh = "refresh-" <> n

    Agent.update(opts.state, fn s ->
      s
      |> put_in([:tokens, access], scopes)
      |> put_in([:refresh, refresh], scopes)
      |> put_in([:claims, access], claims)
    end)

    json(
      conn,
      200,
      %{
        "access_token" => access,
        "token_type" => if(jkt, do: "DPoP", else: opts[:token_type] || "Bearer"),
        "scope" => Enum.join(scopes, " ")
      }
      |> put_present("expires_in", opts[:expires_in])
      |> put_present("refresh_token", if(Map.get(opts, :refresh, true), do: refresh))
    )
  end

  # ---- the external authorization server: JWTs, keys, introspection

  # A token request with a DPoP proof gets a token bound to its key.
  defp bound_key(conn, opts) do
    case {opts[:dpop], get_req_header(conn, "dpop")} do
      {true, [proof]} ->
        url = base(conn) <> issuer_path(opts) <> "/token"
        {:ok, jkt} = Sake.Auth.DPoP.verify(proof, htm: "POST", htu: [url])
        jkt

      _ ->
        nil
    end
  end

  defp claims(conn, scopes, opts, p, jkt) do
    client_id = p["client_id"] || basic_client(conn) || "fake-client"
    now = System.system_time(:second)

    %{
      "iss" => base(conn) <> issuer_path(opts),
      "sub" => if(p["machine"], do: client_id, else: "fake-user"),
      "aud" => p["resource"],
      "client_id" => client_id,
      "scope" => Enum.join(scopes, " "),
      "jti" => Integer.to_string(System.unique_integer([:positive])),
      "iat" => now,
      "exp" => now + (opts[:expires_in] || 300)
    }
    |> put_present("cnf", jkt && %{"jkt" => jkt})
    |> Map.merge(opts[:jwt_claims] || %{})
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp basic_client(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [id, _secret] <- String.split(decoded, ":", parts: 2) do
      URI.decode_www_form(id)
    else
      _ -> nil
    end
  end

  defp signed(claims, opts) do
    Sake.Auth.JWT.sign(claims, opts.jwt, Sake.Auth.JWT.default_alg(opts.jwt), %{
      "typ" => opts[:jwt_typ] || "at+jwt",
      "kid" => "fake-1"
    })
  end

  defp jwks(opts) do
    Agent.get(opts.state, & &1[:jwks]) ||
      %{"keys" => [Map.put(Sake.Auth.JWT.public_jwk(opts.jwt), "kid", "fake-1")]}
  end

  defp introspect(conn, params, %{introspection: {id, secret}} = opts) do
    expected = "Basic " <> Base.encode64(id <> ":" <> secret)

    if get_req_header(conn, "authorization") == [expected] do
      state = Agent.get(opts.state, & &1)
      token = params["token"]

      case state.claims[token] do
        claims when is_map(claims) and not is_map_key(state.revoked, token) ->
          json(conn, 200, Map.put(claims, "active", true))

        _ ->
          json(conn, 200, %{"active" => false})
      end
    else
      json(conn, 401, %{"error" => "invalid_client"})
    end
  end

  defp introspect(conn, _params, _opts), do: send_resp(conn, 404, "")

  defp register(conn, params, opts) do
    json(
      conn,
      201,
      Map.merge(
        %{"client_id" => "registered-client", "client_name" => params["client_name"]},
        opts[:registration] || %{}
      )
    )
  end

  # ---- helpers

  @doc "A fresh state Agent for the issued codes and tokens."
  def state do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{codes: %{}, tokens: %{}, refresh: %{}, idp_refresh: %{}, claims: %{}, revoked: %{}}
      end)

    agent
  end

  defp base(conn), do: "http://#{conn.host}:#{conn.port}"

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
