defmodule Sake.Plug do
  @moduledoc """
  The MCP endpoint. Mount it once per server:

      forward "/mcp", Sake.Plug, server: MyApp.MCP

  Options: `server:` (required), `auth:` (`true` protects the endpoint with
  `Sake.Auth`), `scope:` (a function of the conn that returns the host's
  principal; default `conn.assigns[:sake_scope]`), `origins:` (allowed
  `Origin` values; default the host's own origin; `:any` disables the
  check), `json_limit:` (bytes, default 4 MB), `keepalive:` (ms between SSE
  comments, default 15 000), `secret:` (binary or `{m, f, a}`; default the
  `Sake` configuration), `reraise:` (re-raise tool exceptions, for tests).

  The endpoint serves the modern protocol (2026-07-28) and the three
  handshake-era revisions on the same path.
  """

  @behaviour Plug
  import Plug.Conn

  alias Sake.{Context, JSONRPC, Protocol}
  alias Sake.Plug.{Headers, Origin, ProtocolVersion}
  alias Sake.Server.{Dispatch, Legacy, Session}

  @impl true
  def init(opts) do
    server = opts[:server] || raise(ArgumentError, "Sake.Plug needs a server: option")

    %{
      server: server,
      auth: opts[:auth] || false,
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
    case Sake.Auth.Bearer.check(conn, opts) do
      {:ok, conn} -> route(conn, opts)
      {:error, conn} -> conn
    end
  end

  defp route(%{method: "POST"} = conn, opts), do: post(conn, opts)

  defp route(%{method: "GET"} = conn, opts) do
    case legacy_session(conn, opts) do
      {:ok, session, id} -> Sake.Plug.Stream.legacy(conn, opts, session, id)
      :none -> send_resp(conn, 405, "")
    end
  end

  defp route(%{method: "DELETE"} = conn, opts) do
    case legacy_session(conn, opts) do
      {:ok, _session, _id} -> send_resp(conn, 204, "")
      :none -> send_resp(conn, 405, "")
    end
  end

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
         {:ok, body, conn} <- body(conn, opts),
         {:ok, json} <- decode(body),
         {:ok, parsed} <- parse(json) do
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
      {:error, :accept} ->
        send_error(
          conn,
          406,
          nil,
          JSONRPC.code(:invalid_request),
          "Accept must include application/json and text/event-stream"
        )

      {:error, :too_large} ->
        send_resp(conn, 413, "")

      {:error, :json} ->
        send_error(conn, 400, nil, JSONRPC.code(:parse_error), "Parse error")

      {:error, :malformed} ->
        send_error(conn, 400, nil, JSONRPC.code(:invalid_request), "Invalid request")
    end
  end

  defp accept(conn) do
    accept = conn |> get_req_header("accept") |> Enum.join(",") |> String.downcase()

    if String.contains?(accept, "application/json") and
         String.contains?(accept, "text/event-stream"),
       do: :ok,
       else: {:error, :accept}
  end

  defp body(conn, opts) do
    case read_body(conn, length: opts.json_limit, read_length: opts.json_limit) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, :too_large}
      {:error, _} -> {:error, :json}
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :json}
    end
  end

  defp parse(json) do
    case JSONRPC.parse(json) do
      {:error, :malformed} -> {:error, :malformed}
      parsed -> {:ok, parsed}
    end
  end

  # An `initialize` request always opens a legacy session, even when the
  # `MCP-Protocol-Version` header names the modern revision (the header
  # describes the transport the client used for this one request, not the
  # session it is asking to start).
  defp initialize_or_modern(conn, opts, {:request, _, "initialize", _} = parsed, header_version),
    do: legacy(conn, opts, parsed, header_version)

  defp initialize_or_modern(conn, opts, parsed, header_version),
    do: modern(conn, opts, parsed, header_version)

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

      true ->
        modern_request(conn, opts, parsed, version, meta)
    end
  end

  defp modern_request(conn, opts, {:request, id, method, params} = parsed, version, meta) do
    spec = tool_spec(opts.server, method, params)

    case Headers.validate(conn, parsed, spec) do
      {:error, message} ->
        send_error(conn, 400, id, JSONRPC.code(:header_mismatch), message)

      :ok ->
        ctx = modern_context(conn, opts, version, meta)
        respond(conn, opts, parsed, ctx, &Dispatch.handle/3)
    end
  end

  defp tool_spec(server, "tools/call", params) do
    case Sake.Server.tool(server, params["name"] || "") do
      {:ok, spec} -> spec
      :error -> nil
    end
  end

  defp tool_spec(_server, _method, _params), do: nil

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
        scope: opts.scope.(conn)
      )

    case Legacy.handle(opts.server, parsed, ctx) do
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
        conn = assign(conn, :sake_session_id, id)

        ctx =
          Context.new(
            era: :legacy,
            protocol_version: session.revision,
            client_capabilities: session.capabilities,
            scope: opts.scope.(conn),
            token: conn.assigns[:sake_token],
            scopes: conn.assigns[:sake_scopes] || [],
            conn_assigns: conn.assigns,
            secret: secret(opts),
            server: opts.server,
            reraise: opts.reraise
          )

        conn =
          if Session.renew?(session),
            do:
              put_resp_header(
                conn,
                "mcp-session-id",
                Session.mint(secret(opts), session.revision, session.capabilities)
              ),
            else: conn

        legacy_message(conn, opts, parsed, ctx)
    end
  end

  defp legacy_message(conn, _opts, {:batch, items}, %{protocol_version: "2025-03-26"} = ctx) do
    replies =
      items
      |> Enum.map(fn item -> {item, Legacy.handle(ctx.server, item, ctx)} end)
      |> Enum.flat_map(fn
        {{:request, id, _, _}, {:reply, result}} ->
          [JSONRPC.result(id, result)]

        {{:request, id, _, _}, {:error, error}} ->
          [%{"jsonrpc" => "2.0", "id" => id, "error" => error}]

        {{:request, id, _, _}, {:forbidden, _}} ->
          [JSONRPC.error(id, JSONRPC.code(:invalid_request), "Insufficient scope")]

        {{:request, id, _, _}, _} ->
          [JSONRPC.error(id, JSONRPC.code(:invalid_request), "Not supported in a batch")]

        _ ->
          []
      end)

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

  # ---- one request → one response

  defp respond(conn, opts, {:request, _id, method, params} = parsed, ctx, handler) do
    meta = %{
      method: method,
      component: params["name"] || params["uri"],
      era: ctx.era,
      protocol_version: ctx.protocol_version,
      client_name: ctx.client_info["name"]
    }

    :telemetry.span([:sake, :server, :request], meta, fn ->
      conn = Sake.Plug.Stream.respond(conn, opts, parsed, ctx, handler)
      {conn, Map.put(meta, :cancelled, Process.get(:sake_cancelled, false))}
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
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
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

  def outcome_to_response(conn, id, {:forbidden, scopes}) do
    conn =
      if conn.assigns[:sake_auth],
        do: Sake.Auth.Bearer.insufficient_scope(conn, scopes),
        else: conn

    send_error(conn, 403, id, JSONRPC.code(:invalid_request), "Insufficient scope")
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
