defmodule Sake.Plug do
  @moduledoc """
  The MCP endpoint. Mount it once per server:

      forward "/mcp", Sake.Plug, server: MyApp.MCP

  Options: `server:` (required), `auth:` (`true` protects the endpoint with
  `Sake.Auth`; the name of an `external_auth:` configuration of the `Sake`
  child, such as `:keycloak`, with the tokens of that authorization server,
  see `Sake.Auth.External`), `scope:` (a function of the conn that returns the host's
  principal; default `conn.assigns[:sake_scope]`), `origins:` (allowed
  `Origin` values for a request that sends one — a request with no `Origin`
  header, which is how every non-browser MCP client connects, is always
  allowed; default `nil` refuses any `Origin` at all, so a browser client
  needs this set explicitly; `:any` allows any `Origin`), `json_limit:`
  (bytes, default 4 MB), `keepalive:` (ms between SSE
  comments, default 15 000), `secret:` (binary or `{m, f, a}`; default the
  `Sake` configuration), `reraise:` (re-raise tool exceptions, for tests).

  The endpoint serves the modern protocol (2026-07-28) and the three
  handshake-era revisions on the same path.
  """

  @behaviour Plug
  import Plug.Conn

  alias Sake.Auth.Challenge
  alias Sake.{Context, JSONRPC, Protocol, Trace}
  alias Sake.Plug.{Headers, Origin, ProtocolVersion}
  alias Sake.Server.{Dispatch, Legacy, Session}

  @impl true
  def init(opts) do
    server = opts[:server] || raise(ArgumentError, "Sake.Plug needs a server: option")
    auth = opts[:auth] || false

    unless is_atom(auth),
      do:
        raise(
          ArgumentError,
          "Sake.Plug auth: is true, false or the name of an external_auth: configuration, got #{inspect(auth)}"
        )

    %{
      server: server,
      auth: auth,
      scope: opts[:scope] || (&Sake.Plug.default_scope/1),
      origins: opts[:origins],
      json_limit: opts[:json_limit] || 4_000_000,
      keepalive: opts[:keepalive] || 15_000,
      secret: opts[:secret],
      reraise: opts[:reraise] || false
    }
  end

  @impl true
  def call(conn, opts) do
    if Origin.allowed?(conn, opts.origins) do
      conn |> assign(:sake_auth, opts.auth) |> authenticate(opts)
    else
      send_error(conn, 403, nil, JSONRPC.code(:invalid_request), "Origin not allowed")
    end
  end

  defp authenticate(conn, %{auth: false} = opts), do: route(conn, opts)

  defp authenticate(conn, opts) do
    case Sake.Auth.authenticate(conn, opts) do
      {:ok, conn} -> route(conn, opts)
      {:error, challenge} -> send_challenge(conn, challenge)
    end
  end

  # A refused token: the challenges, the DPoP nonce a `use_dpop_nonce`
  # error asks for, and the JSON-RPC error of an MCP endpoint.
  defp send_challenge(conn, %Challenge{status: 401} = challenge) do
    conn
    |> put_nonce(challenge.nonce)
    |> prepend_resp_headers(for(c <- challenge.www_authenticate, do: {"www-authenticate", c}))
    |> send_error(401, nil, JSONRPC.code(:invalid_request), "Unauthorized")
  end

  defp put_nonce(conn, nil), do: conn
  defp put_nonce(conn, nonce), do: put_resp_header(conn, "dpop-nonce", nonce)

  defp route(%{method: "POST"} = conn, opts), do: post(conn, opts)

  defp route(%{method: "GET"} = conn, opts) do
    case legacy_session(conn, opts) do
      {:ok, session, _id} -> Sake.Plug.Stream.legacy(conn, opts, session)
      :none -> send_resp(conn, 405, "")
    end
  end

  # A legacy session ID is a signed token and the server keeps nothing per
  # session, so there is nothing a DELETE could end: the ID would go on
  # working. The legacy revisions let a server refuse explicit termination
  # with 405, which is the honest answer.
  defp route(%{method: "DELETE"} = conn, _opts), do: send_resp(conn, 405, "")

  defp route(conn, _opts), do: send_resp(conn, 405, "")

  defp legacy_session(conn, opts) do
    with [id | _] <- get_req_header(conn, "mcp-session-id"),
         {:ok, session} <- Session.verify(secret(opts), id) do
      {:ok, session, id}
    else
      _ -> :none
    end
  end

  # ---- POST

  defp post(conn, opts) do
    with :ok <- accept(conn),
         {:ok, json, conn} <- Sake.Auth.Body.json(conn, opts.json_limit) do
      message(conn, opts, json)
    else
      {:error, :accept} ->
        send_error(
          conn,
          406,
          nil,
          JSONRPC.code(:invalid_request),
          "Accept must include application/json and text/event-stream"
        )

      {:error, :too_large, conn} ->
        send_resp(conn, 413, "")

      {:error, :json, conn} ->
        send_error(conn, 400, nil, JSONRPC.code(:parse_error), "Parse error")
    end
  end

  # The body has been read: from here on every answer goes out on the conn
  # the read returned, never the one `post/2` was called with.
  defp message(conn, opts, json) do
    with {:ok, parsed} <- parse(json),
         :ok <- shape(parsed) do
      case ProtocolVersion.detect(conn) do
        {:unsupported, v} ->
          send_error(
            conn,
            400,
            id_of(parsed),
            JSONRPC.code(:unsupported_version),
            "Unsupported protocol version",
            %{
              "supported" => Protocol.supported(),
              "requested" => v
            }
          )

        {:modern, header_version} ->
          initialize_or_modern(conn, opts, parsed, header_version)

        {:legacy, header_version} ->
          legacy(conn, opts, parsed, header_version)
      end
    else
      {:error, :malformed} ->
        send_error(conn, 400, nil, JSONRPC.code(:invalid_request), "Invalid request")

      {:error, :params, id, message} ->
        send_error(conn, 400, id, JSONRPC.code(:invalid_params), message)
    end
  end

  # The parameters Sake reads as objects must be objects: a client that
  # sends anything else gets -32602, never a crash.
  @object_params ["_meta", "arguments", "inputResponses"]

  @doc false
  def shape({:batch, items}) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case shape(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def shape({:request, id, _method, params}), do: object_params(id, params)
  def shape({:notification, _method, params}), do: object_params(nil, params)
  def shape(_parsed), do: :ok

  defp object_params(id, params) do
    case Enum.find(@object_params, &(Map.has_key?(params, &1) and not is_map(params[&1]))) do
      nil -> :ok
      name -> {:error, :params, id, "#{name} must be an object"}
    end
  end

  defp accept(conn) do
    accept = conn |> get_req_header("accept") |> Enum.join(",") |> String.downcase()

    if String.contains?(accept, "application/json") and
         String.contains?(accept, "text/event-stream"),
       do: :ok,
       else: {:error, :accept}
  end

  defp parse(json) do
    case JSONRPC.parse(json) do
      {:error, :malformed} -> {:error, :malformed}
      parsed -> {:ok, parsed}
    end
  end

  # An `initialize` request opens a legacy session, even when the
  # `MCP-Protocol-Version` header names the modern revision (the header
  # describes the transport the client used for this one request, not the
  # session it is asking to start). One that carries the modern per-request
  # `_meta` comes from a modern client, though, and is served statelessly
  # like any other modern request: `initialize` is not a modern method, so
  # it gets "method not found".
  defp initialize_or_modern(
         conn,
         opts,
         {:request, _, "initialize", params} = parsed,
         header_version
       ) do
    if modern_meta?(params),
      do: modern(conn, opts, parsed, header_version),
      else: legacy(conn, opts, parsed, header_version)
  end

  defp initialize_or_modern(conn, opts, parsed, header_version),
    do: modern(conn, opts, parsed, header_version)

  defp modern_meta?(%{"_meta" => meta}) when is_map(meta),
    do: Map.has_key?(meta, Protocol.meta(:protocol_version))

  defp modern_meta?(_params), do: false

  # ---- modern

  defp modern(conn, _opts, {:batch, _}, _version),
    do: send_error(conn, 400, nil, JSONRPC.code(:invalid_request), "Batches are not accepted")

  defp modern(conn, _opts, {:response, _, _}, _version),
    do:
      send_error(conn, 400, nil, JSONRPC.code(:invalid_request), "Clients do not send responses")

  defp modern(conn, _opts, {:error_response, _, _}, _version),
    do:
      send_error(conn, 400, nil, JSONRPC.code(:invalid_request), "Clients do not send responses")

  defp modern(conn, _opts, {:notification, _method, _params}, _version),
    do: send_resp(conn, 202, "")

  defp modern(conn, opts, {:request, id, _method, params} = parsed, version) do
    meta = params["_meta"] || %{}

    cond do
      not Map.has_key?(meta, Protocol.meta(:protocol_version)) ->
        send_error(
          conn,
          400,
          id,
          JSONRPC.code(:invalid_params),
          "Missing #{Protocol.meta(:protocol_version)} in _meta"
        )

      meta[Protocol.meta(:protocol_version)] != version ->
        send_error(
          conn,
          400,
          id,
          JSONRPC.code(:header_mismatch),
          "MCP-Protocol-Version header does not match the request body"
        )

      not is_map(meta[Protocol.meta(:client_capabilities)]) ->
        send_error(
          conn,
          400,
          id,
          JSONRPC.code(:invalid_params),
          "Missing #{Protocol.meta(:client_capabilities)} in _meta"
        )

      not (is_nil(meta[Protocol.meta(:log_level)]) or
               Sake.Progress.level?(meta[Protocol.meta(:log_level)])) ->
        send_error(conn, 400, id, JSONRPC.code(:invalid_params), "Unknown log level")

      true ->
        modern_request(conn, opts, parsed, version, meta)
    end
  end

  # The tool's spec, for its `Mcp-Param-*` headers, is looked up with the
  # request's context: a proxied tool is one the principal's upstream lists.
  defp modern_request(conn, opts, {:request, id, method, params} = parsed, version, meta) do
    ctx = modern_context(conn, opts, version, meta)
    spec = tool_spec(opts.server, method, params, ctx)

    case Headers.validate(conn, parsed, spec) do
      {:error, message} -> send_error(conn, 400, id, JSONRPC.code(:header_mismatch), message)
      :ok -> respond(conn, opts, parsed, ctx, &Dispatch.handle/3)
    end
  end

  defp tool_spec(server, "tools/call", params, ctx) do
    case Sake.Server.tool(server, params["name"] || "", ctx) do
      {:ok, spec} -> spec
      :error -> nil
    end
  end

  defp tool_spec(_server, _method, _params, _ctx), do: nil

  defp modern_context(conn, opts, version, meta) do
    Context.new(
      era: :modern,
      protocol_version: version,
      client_info: meta[Protocol.meta(:client_info)] || %{},
      client_capabilities: meta[Protocol.meta(:client_capabilities)],
      log_level: meta[Protocol.meta(:log_level)],
      trace: Map.take(meta, ["traceparent", "tracestate", "baggage"]),
      scope: opts.scope.(conn),
      token: conn.assigns[:sake_token],
      scopes: conn.assigns[:sake_scopes] || [],
      conn_assigns: conn.assigns,
      secret: secret(opts),
      server: opts.server,
      reraise: opts.reraise
    )
  end

  # ---- legacy

  defp legacy(conn, opts, {:request, id, "initialize", _} = parsed, _header_version) do
    ctx =
      Context.new(
        era: :legacy,
        secret: secret(opts),
        server: opts.server,
        reraise: opts.reraise,
        scope: opts.scope.(conn),
        conn_assigns: conn.assigns
      )

    outcome =
      Trace.server(parsed, ctx, {:http, conn}, fn ->
        opts.server |> Legacy.handle(parsed, ctx) |> Trace.outcome()
      end)

    case outcome do
      {:initialize, revision, caps, result} ->
        conn
        |> put_resp_header("mcp-session-id", Session.mint(secret(opts), revision, caps))
        |> send_json(200, JSONRPC.result(id, result))

      {:error, error} ->
        send_json(conn, 400, %{"jsonrpc" => "2.0", "id" => id, "error" => error})
    end
  end

  defp legacy(conn, opts, parsed, _header_version) do
    case legacy_session(conn, opts) do
      :none ->
        send_error(conn, 404, id_of(parsed), JSONRPC.code(:invalid_request), "Unknown session")

      {:ok, session, id} ->
        conn = conn |> assign(:sake_session_id, id) |> assign(:sake_session_nonce, session.nonce)

        ctx =
          Context.new(
            era: :legacy,
            protocol_version: session.revision,
            client_capabilities: session.capabilities,
            log_level: session.log_level,
            scope: opts.scope.(conn),
            token: conn.assigns[:sake_token],
            scopes: conn.assigns[:sake_scopes] || [],
            conn_assigns: conn.assigns,
            secret: secret(opts),
            server: opts.server,
            reraise: opts.reraise
          )

        conn = renew_session(conn, opts, session, parsed)
        legacy_message(conn, opts, parsed, ctx)
    end
  end

  # `logging/setLevel` takes effect at once (the level rides in the signed
  # session ID, since the server keeps no per-session state): the response
  # carries a re-minted ID, which every conformant client picks up from
  # any response, not only `initialize`. Otherwise the ID is re-minted
  # only when it is getting old, carrying the same level forward.
  defp renew_session(conn, opts, session, {:request, _, "logging/setLevel", %{"level" => level}})
       when is_binary(level) do
    if Sake.Progress.level?(level),
      do: put_resp_header(conn, "mcp-session-id", Session.renew(secret(opts), session, level)),
      else: conn
  end

  defp renew_session(conn, opts, session, _parsed) do
    if Session.renew?(session) do
      put_resp_header(
        conn,
        "mcp-session-id",
        Session.renew(secret(opts), session, session.log_level)
      )
    else
      conn
    end
  end

  defp legacy_message(conn, _opts, {:batch, items}, %{protocol_version: "2025-03-26"} = ctx) do
    replies = batch_replies(items, ctx)
    if replies == [], do: send_resp(conn, 202, ""), else: send_json(conn, 200, replies)
  end

  defp legacy_message(conn, _opts, {:batch, _}, _ctx),
    do: send_error(conn, 400, nil, JSONRPC.code(:invalid_request), "Batches are not accepted")

  defp legacy_message(conn, _opts, {:notification, _, _}, _ctx), do: send_resp(conn, 202, "")

  defp legacy_message(conn, opts, {:response, id, result}, ctx),
    do: Sake.Plug.Stream.client_response(conn, opts, ctx, id, {:ok, result})

  defp legacy_message(conn, opts, {:error_response, id, error}, ctx),
    do: Sake.Plug.Stream.client_response(conn, opts, ctx, id, {:error, error})

  defp legacy_message(conn, opts, {:request, _, _, _} = parsed, ctx),
    do: respond(conn, opts, parsed, ctx, &Legacy.handle/3)

  # A 2025-03-26 batch runs its items one after the other, with no stream
  # to write on: a subscription is refused item by item, and a component
  # that elicits finds no client to ask. Shared with `Sake.Stdio`.
  @doc false
  def batch_replies(items, ctx) do
    items
    |> Enum.map(fn item -> {item, Legacy.handle(ctx.server, item, ctx)} end)
    |> Enum.flat_map(fn
      {{:request, id, _, _}, {:reply, result}} ->
        [JSONRPC.result(id, result)]

      {{:request, id, _, _}, {:error, error}} ->
        [%{"jsonrpc" => "2.0", "id" => id, "error" => error}]

      {{:request, id, _, _}, {:forbidden, scopes}} ->
        [%{"jsonrpc" => "2.0", "id" => id, "error" => Sake.Plug.Stream.forbidden(scopes)}]

      {{:request, id, _, _}, {:insufficient_user_authentication, _refusal}} ->
        [
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => Sake.Plug.Stream.insufficient_user_authentication()
          }
        ]

      {{:request, id, _, _}, _} ->
        [JSONRPC.error(id, JSONRPC.code(:invalid_request), "Not supported in a batch")]

      _ ->
        []
    end)
  end

  # ---- one request → one response

  defp respond(conn, opts, {:request, _id, method, params} = parsed, ctx, handler) do
    meta = %{
      method: method,
      component: params["name"] || params["uri"],
      era: ctx.era,
      protocol_version: ctx.protocol_version,
      client_name: ctx.client_info["name"]
    }

    Trace.server(parsed, ctx, {:http, conn}, fn ->
      :telemetry.span([:sake, :server, :request], meta, fn ->
        conn = Sake.Plug.Stream.respond(conn, opts, parsed, ctx, handler)
        {conn, Map.put(meta, :cancelled, Process.get(:sake_cancelled, false))}
      end)
    end)
  end

  # ---- helpers

  # The default `scope:` function, as a remote capture so `init/1` can
  # return it from contexts (Plug.Router, Plug.Builder pipelines) that
  # need to store the initialized options as a compile-time literal.
  @doc false
  def default_scope(conn), do: conn.assigns[:sake_scope]

  @doc false
  def secret(opts), do: Sake.Secret.resolve(opts.secret)

  @doc false
  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Sake.JSON.encode_to_iodata!(body))
  end

  @doc false
  def send_error(conn, status, id, code, message, data \\ nil) do
    send_json(conn, status, JSONRPC.error(id, code, message, data))
  end

  @doc false
  def outcome_to_response(conn, id, {:reply, result}),
    do: send_json(conn, 200, JSONRPC.result(id, result))

  def outcome_to_response(conn, id, {:error, %{"code" => -32_601} = error}),
    do: send_json(conn, 404, %{"jsonrpc" => "2.0", "id" => id, "error" => error})

  def outcome_to_response(conn, id, {:error, %{"code" => code} = error})
      when code in [-32_020, -32_021, -32_022],
      do: send_json(conn, 400, %{"jsonrpc" => "2.0", "id" => id, "error" => error})

  def outcome_to_response(conn, id, {:error, error}),
    do: send_json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "error" => error})

  # A refusal that names no scopes (a middleware's `:forbidden`) has no
  # challenge: no token the client could step up to would lift it.
  def outcome_to_response(conn, id, {:forbidden, scopes}) do
    conn =
      if conn.assigns[:sake_auth] && scopes != [] do
        %Challenge{www_authenticate: [header]} = Sake.Auth.insufficient_scope(conn, scopes)
        put_resp_header(conn, "www-authenticate", header)
      else
        conn
      end

    send_json(conn, 403, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => Sake.Plug.Stream.forbidden(scopes)
    })
  end

  # RFC 9470: a token whose person signed in too weakly or too long ago
  # gets a 401 whose challenge says how to sign in, in the token's
  # scheme, as `insufficient_scope` is.
  def outcome_to_response(conn, id, {:insufficient_user_authentication, refusal}) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => Sake.Plug.Stream.insufficient_user_authentication()
    }

    if conn.assigns[:sake_auth] do
      %Challenge{www_authenticate: [header]} =
        Sake.Auth.insufficient_user_authentication(
          conn,
          Map.take(refusal, [:acr_values, :max_age]),
          refusal.reason,
          refusal.scopes
        )

      conn |> put_resp_header("www-authenticate", header) |> send_json(401, body)
    else
      send_json(conn, 403, body)
    end
  end

  def outcome_to_response(conn, _id, :noreply), do: send_resp(conn, 202, "")

  def outcome_to_response(conn, id, {:subscribe, _}),
    do: send_json(conn, 200, JSONRPC.result(id, %{}))

  def outcome_to_response(conn, id, {:unsubscribe, _}),
    do: send_json(conn, 200, JSONRPC.result(id, %{}))

  def outcome_to_response(conn, id, {:listen, _}),
    do:
      send_error(
        conn,
        400,
        id,
        JSONRPC.code(:invalid_request),
        "subscriptions/listen needs the stream registry"
      )

  defp id_of({:request, id, _, _}), do: id
  defp id_of(_), do: nil
end
