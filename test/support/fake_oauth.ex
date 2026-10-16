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
  #   * `:issuer_path` — the authorization server's path ("" by default).
  #   * `:metadata_at` — where its metadata is served, by default the RFC 8414
  #     path-inserted URL.
  #   * `:metadata` — fields merged into its metadata (`nil` removes one).
  #   * `:iss` — `:correct` (default), `:trailing_slash`, `:omit`, or a
  #     string to send.
  #   * `:call_scopes` — the scopes `tools/call` needs (a 403 otherwise);
  #     with `:deny_calls`, every call is refused with them anyway.
  #   * `:legacy` — answer as a 2025-06-18 server instead.
  #   * `:grant` — the scopes every token gets, whatever was asked for.
  #   * `:expires_in`, `:refresh` (default true) — the token answers.
  #   * `:token_type` — the `token_type` they give (default "Bearer").
  #   * `:registration` — fields merged into the registration answer.
  #   * `:grant_error` — an error code every client credentials or JWT
  #     bearer request is answered with.
  #   * `:idp_error` — an error code the identity provider's token
  #     exchange (at /idp/token, metadata at the RFC 8414 URL of the
  #     issuer `/idp`) answers with; otherwise it returns `jag-` and the
  #     subject token as the ID-JAG.
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
      path == "/.well-known/oauth-authorization-server/idp" -> json(conn, 200, idp_metadata(conn))
      resource_metadata?(path, opts) -> resource_metadata(conn, opts)
      path == metadata_path(opts) -> json(conn, 200, metadata(conn, opts))
      path == issuer_path(opts) <> "/authorize" -> authorize(conn, opts)
      true -> send_resp(conn, 404, "")
    end
  end

  defp route(conn, "POST", path, params, opts) do
    cond do
      path == "/idp/token" -> token_exchange(conn, params, opts)
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

  defp token(conn, %{"grant_type" => "authorization_code"} = p, opts) do
    request = Agent.get(opts.state, &get_in(&1, [:codes, p["code"]]))

    if request &&
         Grant.challenge(p["code_verifier"] || "") == request["code_challenge"],
       do: issue(conn, opts[:grant] || String.split(request["scope"] || ""), opts),
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
          Map.put(opts, :refresh, false)
        )

      error ->
        json(conn, 400, %{"error" => error})
    end
  end

  # ---- the enterprise identity provider

  defp idp_metadata(conn) do
    %{
      "issuer" => base(conn) <> "/idp",
      "token_endpoint" => base(conn) <> "/idp/token",
      "token_endpoint_auth_methods_supported" => ["client_secret_post"]
    }
  end

  defp token_exchange(conn, p, opts) do
    case opts[:idp_error] do
      nil ->
        json(conn, 200, %{
          "access_token" => "jag-" <> p["subject_token"],
          "issued_token_type" => "urn:ietf:params:oauth:token-type:id-jag",
          "token_type" => "N_A"
        })

      error ->
        json(conn, 400, %{"error" => error})
    end
  end

  defp issue(conn, scopes, opts) do
    n = Integer.to_string(System.unique_integer([:positive]))
    access = "access-" <> n
    refresh = "refresh-" <> n

    Agent.update(opts.state, fn s ->
      s |> put_in([:tokens, access], scopes) |> put_in([:refresh, refresh], scopes)
    end)

    json(
      conn,
      200,
      %{
        "access_token" => access,
        "token_type" => opts[:token_type] || "Bearer",
        "scope" => Enum.join(scopes, " ")
      }
      |> put_present("expires_in", opts[:expires_in])
      |> put_present("refresh_token", if(Map.get(opts, :refresh, true), do: refresh))
    )
  end

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
    {:ok, agent} = Agent.start_link(fn -> %{codes: %{}, tokens: %{}, refresh: %{}} end)
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
