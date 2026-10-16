defmodule Sake.Trace do
  @moduledoc false
  # OpenTelemetry spans for MCP, after the semantic conventions for MCP
  # (https://opentelemetry.io/docs/specs/semconv/gen-ai/mcp/): a SERVER
  # span for every request a server serves, a CLIENT span for every
  # request `Sake.Client` sends, and an INTERNAL `execute_tool` span for
  # the run of a task. The trace context travels in the request's
  # `params._meta` (`traceparent`, `tracestate` and `baggage`, written by
  # the configured propagators): the client injects it, and the server
  # takes it as the parent of its span and links the context of the
  # transport (the HTTP server span, when the host instruments HTTP).
  #
  # Each span is made current in the process that runs the component, so
  # what the component does under its own instrumentation (Ecto, Req)
  # nests under it, and the baggage the client sent is the component's.
  #
  # `opentelemetry_api` is an optional dependency: every call into it goes
  # through `Sake.Trace.OpenTelemetry`, a module that without it does
  # nothing (and is never called: `enabled?/0` is false). This module
  # decides the spans' names, attributes and status; that one makes them
  # and moves trace contexts around. With the API but no SDK, the API
  # itself does nothing.
  #
  # `config :sake, :opentelemetry, enabled: false` turns the spans off;
  # `record_content: true` adds the tool arguments and results and the
  # prompt arguments, which the conventions leave opt-in because they may
  # be sensitive.

  alias Sake.Context
  alias Sake.Trace.OpenTelemetry, as: Backend

  # The span of the request this process serves, its kind and method, for
  # `outcome/1`.
  @current {__MODULE__, :span}

  # The codes the conventions count as the caller's mistake rather than
  # the server's failure, on a SERVER span: parse error, invalid request,
  # method not found, invalid params (an unknown tool too), and the legacy
  # resource-not-found. On a CLIENT span every error code is an error.
  @not_errors [-32_700, -32_600, -32_601, -32_602, -32_002]

  @type transport ::
          {:http, Plug.Conn.t()} | {:stdio, String.t() | nil} | {:local, String.t() | nil}

  @doc "Whether Sake makes spans: `opentelemetry_api` is there, and the host has not turned them off."
  @spec enabled?() :: boolean()
  def enabled? do
    Code.ensure_loaded?(:otel_tracer) and config(:enabled, true)
  end

  defp config(key, default),
    do: Keyword.get(Application.get_env(:sake, :opentelemetry, []), key, default)

  # ---- server

  @doc """
  Runs `fun` under the SERVER span of a request: the child of the trace
  context in the request's `_meta`, linked to the transport's; without
  one in `_meta`, the child of the transport's (see
  `Sake.Trace.OpenTelemetry.server_span/4`). `transport` is `{:http,
  conn}`, `{:stdio, session}` or `{:local, session}` (`Sake.Test`),
  `session` the legacy session's identity.
  """
  @spec server(Sake.JSONRPC.parsed(), Context.t(), transport(), (-> result)) :: result
        when result: var
  def server({:request, id, method, params}, ctx, transport, fun) do
    if enabled?() do
      attributes =
        %{
          "mcp.protocol.version" => if(method != "initialize", do: ctx.protocol_version),
          "mcp.session.id" => session(transport)
        }
        |> Map.merge(request_attributes(id, method, params))
        |> Map.merge(transport_attributes(transport))

      params["_meta"]
      |> carrier()
      |> Backend.server_span(headers(transport), name(method, params), attributes)
      |> run(:server, method, fun)
    else
      fun.()
    end
  end

  defp carrier(meta) when is_map(meta) do
    for key <- ["traceparent", "tracestate", "baggage"],
        value = meta[key],
        is_binary(value),
        do: {key, value}
  end

  defp carrier(_meta), do: []

  defp headers({:http, conn}), do: conn.req_headers
  defp headers(_transport), do: []

  defp session({:http, conn}), do: conn.assigns[:sake_session_nonce]
  defp session({_transport, session}), do: session

  defp transport_attributes({:http, conn}) do
    %{
      "network.transport" => "tcp",
      "network.protocol.name" => "http",
      "network.protocol.version" => http_version(conn),
      "client.address" => to_string(:inet.ntoa(conn.remote_ip))
    }
  end

  defp transport_attributes({:stdio, _session}), do: %{"network.transport" => "pipe"}
  defp transport_attributes({:local, _session}), do: %{"network.transport" => "inproc"}

  defp http_version(conn),
    do: conn |> Plug.Conn.get_http_protocol() |> to_string() |> String.replace_prefix("HTTP/", "")

  # ---- client

  @doc """
  Runs `fun`, one request of `Sake.Client` (it returns `{:ok, result,
  session}` or `{:error, reason, session}`), under a CLIENT span.
  """
  @spec client(Sake.Client.Session.t(), String.t(), map(), (-> result)) :: result
        when result: var
  def client(session, method, params, fun) do
    if enabled?() do
      attributes =
        %{
          "mcp.protocol.version" => session.revision,
          "mcp.session.id" => session.session_id
        }
        |> Map.merge(request_attributes(session.next_id, method, params))
        |> Map.merge(server_attributes(session))

      name(method, params)
      |> Backend.child_span(:client, attributes)
      |> run(:client, method, fn ->
        result = fun.()
        record(client_outcome(result))
        result
      end)
    else
      fun.()
    end
  end

  defp server_attributes(%{stdio: pid}) when is_pid(pid), do: %{"network.transport" => "pipe"}
  defp server_attributes(%{local: %{}}), do: %{"network.transport" => "inproc"}

  defp server_attributes(%{url: url}) do
    uri = URI.parse(url)

    %{
      "network.transport" => "tcp",
      "network.protocol.name" => "http",
      "server.address" => uri.host,
      "server.port" => uri.port
    }
  end

  defp client_outcome({:ok, result, _session}), do: {:reply, result}

  defp client_outcome({:error, {:rpc, %{"code" => _} = error}, _session}), do: {:error, error}

  defp client_outcome({:error, reason, _session}),
    do: {:failed, error_type(reason)}

  @doc """
  `params` with the current trace context added to its `_meta`, beside
  what is there already (on the modern protocol, the protocol's own
  fields). Both eras allow `_meta` on every request.
  """
  @spec inject(map()) :: map()
  def inject(params), do: if(enabled?(), do: Backend.inject(params), else: params)

  @doc """
  The low-cardinality `error.type` of a reason `Sake.Client` returns: the
  JSON-RPC error code, the HTTP status, the exception's module, or the
  reason's own name.
  """
  @spec error_type(term()) :: String.t()
  def error_type({:rpc, %{"code" => code}}), do: to_string(code)
  def error_type({:http, status, _body}), do: to_string(status)
  def error_type(%{__exception__: true, __struct__: module}), do: inspect(module)
  def error_type(reason) when is_atom(reason), do: to_string(reason)
  def error_type({reason, _detail}) when is_atom(reason), do: to_string(reason)
  def error_type(_reason), do: "_OTHER"

  # ---- tasks

  @doc """
  Runs `fun`, a task's tool, under an `execute_tool` span. Started from a
  function `bind/1` made in the `tools/call` request, the span is the
  child of that request's SERVER span: the task is the rest of the call
  the client made, so the tool's work stays in the client's trace, even
  though the span outlives its parent.
  """
  @spec task(String.t(), String.t(), (-> result)) :: result when result: var
  def task(tool, task_id, fun) do
    if enabled?() do
      attributes = %{
        "gen_ai.operation.name" => "execute_tool",
        "gen_ai.tool.name" => tool,
        "gen_ai.tool.call.id" => task_id
      }

      "execute_tool #{tool}"
      |> Backend.child_span(:internal, attributes)
      |> run(:internal, "tools/call", fun)
    else
      fun.()
    end
  end

  # ---- middleware

  @doc """
  Marks the current span with the middleware halt that refused its
  request (see `Sake.Middleware`): the event and the plug. Whether the
  span is an error follows from the answer the client gets, as for any
  other request.
  """
  @spec halt(atom(), module()) :: :ok
  def halt(event, plug) do
    if enabled?() do
      _ =
        Backend.set(Backend.current(), %{
          "sake.middleware.event" => to_string(event),
          "sake.middleware.plug" => inspect(plug)
        })
    end

    :ok
  end

  # ---- the span of this process

  @doc """
  `fun` bound to the caller's trace context, to run in another process
  (a request's handler task, a task's worker) as part of the same trace.
  """
  @spec bind((-> result)) :: (-> result) when result: var
  def bind(fun), do: if(enabled?(), do: Backend.bind(fun), else: fun)

  @doc """
  Records how the request this process serves ended on its span: a
  `Sake.Plug`/`Sake.Stdio` outcome (`{:reply, result}`, `{:error,
  error}`, ...). Returns the outcome.
  """
  @spec outcome(term()) :: term()
  def outcome(outcome) do
    _ = record(outcome)
    outcome
  end

  defp run(span, kind, method, fun) do
    previous = Process.put(@current, {span, kind, method})

    try do
      Backend.within(span, fun)
    after
      restore(previous)
    end
  end

  defp restore(nil), do: Process.delete(@current)
  defp restore(previous), do: Process.put(@current, previous)

  defp record(outcome) do
    case Process.get(@current) do
      {span, kind, method} ->
        span |> Backend.set(attributes(outcome, method)) |> status(outcome, kind)

      nil ->
        :ok
    end
  end

  # A legacy `initialize` names the revision only in its answer: the
  # server's outcome, or the result the client got.
  defp attributes({:initialize, revision, _caps, _result}, _method),
    do: %{"mcp.protocol.version" => revision}

  defp attributes({:reply, %{"protocolVersion" => revision}}, "initialize"),
    do: %{"mcp.protocol.version" => revision}

  defp attributes({:reply, %{"isError" => true}}, _method), do: %{"error.type" => "tool_error"}

  # Opt-in, and only for the tool's own result: not for a task or a
  # request for input.
  defp attributes({:reply, result}, "tools/call") do
    if config(:record_content, false) and result["resultType"] in [nil, "complete"],
      do: %{"gen_ai.tool.call.result" => json(result["structuredContent"] || result["content"])},
      else: %{}
  end

  defp attributes({:error, %{"code" => code}}, _method),
    do: %{"rpc.response.status_code" => to_string(code)}

  defp attributes({:forbidden, _scopes}, _method),
    do: %{"rpc.response.status_code" => to_string(Sake.JSONRPC.code(:invalid_request))}

  defp attributes({:failed, type}, _method), do: %{"error.type" => type}
  defp attributes(_outcome, _method), do: %{}

  defp status(span, {:reply, %{"isError" => true}}, _kind), do: Backend.error(span, "")

  defp status(span, {:error, %{"code" => code} = error}, kind)
       when kind != :server or code not in @not_errors do
    Backend.set(span, %{"error.type" => to_string(code)})
    Backend.error(span, to_string(error["message"]))
  end

  defp status(span, {:failed, _type}, _kind), do: Backend.error(span, "")
  defp status(_span, _outcome, _kind), do: :ok

  # ---- the conventions' names and attributes

  # `{mcp.method.name} {target}`, the target being a tool or prompt name;
  # a resource URI is left out of the name, as too many different names.
  defp name(method, %{"name" => target}) when method in ["tools/call", "prompts/get"],
    do: "#{method} #{target}"

  defp name(method, _params), do: method

  defp request_attributes(id, method, params) do
    %{"mcp.method.name" => method, "jsonrpc.request.id" => id && to_string(id)}
    |> Map.merge(target_attributes(method, params))
    |> Map.merge(if config(:record_content, false), do: content(method, params), else: %{})
  end

  defp target_attributes("tools/call", %{"name" => name}),
    do: %{"gen_ai.tool.name" => name, "gen_ai.operation.name" => "execute_tool"}

  defp target_attributes("prompts/get", %{"name" => name}), do: %{"gen_ai.prompt.name" => name}

  defp target_attributes(method, %{"uri" => uri})
       when method in ["resources/read", "resources/subscribe", "resources/unsubscribe"],
       do: %{"mcp.resource.uri" => uri}

  defp target_attributes(_method, _params), do: %{}

  # Opt-in: what the client sent the tool or the prompt.
  defp content("tools/call", params),
    do: %{"gen_ai.tool.call.arguments" => json(params["arguments"] || %{})}

  defp content("prompts/get", %{"arguments" => %{} = arguments}) do
    for {name, value} <- arguments, is_binary(value), into: %{} do
      {"gen_ai.prompt.variable.#{name}", value}
    end
  end

  defp content(_method, _params), do: %{}

  defp json(value) do
    Sake.JSON.encode!(value)
  rescue
    _ -> nil
  end
end

if Code.ensure_loaded?(:otel_tracer) do
  defmodule Sake.Trace.OpenTelemetry do
    @moduledoc false
    # The calls `Sake.Trace` makes into `opentelemetry_api`. A span here is
    # the context it is current in (`otel_ctx`), so that making it current
    # somewhere else is one `attach`.

    @type span :: :otel_ctx.t()

    @doc """
    Starts a SERVER span. The context in `meta` (the request's `_meta`) is
    the parent, and the ambient one, or else the context in `headers` (the
    HTTP request's own `traceparent`, when nothing instruments HTTP), a
    link: one MCP request may take several HTTP requests, and one HTTP
    stream may carry several MCP requests, so the two are independent.
    Without a context in `meta`, the transport's is the parent.
    """
    @spec server_span(carrier, carrier, String.t(), map()) :: span
          when carrier: [{String.t(), String.t()}]
    def server_span(meta, headers, name, attributes) do
      remote = remote(meta)
      transport = transport(headers)

      {parent, links} =
        cond do
          not span?(remote) -> {transport || remote, []}
          transport -> {remote, [transport]}
          true -> {remote, []}
        end

      start(parent, name, :server, attributes, links)
    end

    @doc "The current context, whose span is the one `set/2` marks."
    @spec current() :: span
    def current, do: :otel_ctx.get_current()

    @doc "Starts a span, the child of the current one."
    @spec child_span(String.t(), atom(), map()) :: span
    def child_span(name, kind, attributes),
      do: start(:otel_ctx.get_current(), name, kind, attributes, [])

    @doc "Runs `fun` with `span` current, and ends the span."
    @spec within(span, (-> result)) :: result when result: var
    def within(span, fun) do
      token = :otel_ctx.attach(span)

      try do
        fun.()
      catch
        class, reason ->
          span_ctx = span_ctx(span)
          _ = :otel_span.record_exception(span_ctx, class, reason, __STACKTRACE__, %{})
          _ = :otel_span.set_status(span_ctx, :error, Exception.format_banner(class, reason))
          :erlang.raise(class, reason, __STACKTRACE__)
      after
        _ = :otel_span.end_span(span_ctx(span))
        _ = :otel_ctx.detach(token)
      end
    end

    @spec set(span, map()) :: span
    def set(span, attributes) do
      _ = :otel_span.set_attributes(span_ctx(span), present(attributes))
      span
    end

    @spec error(span, String.t()) :: :ok
    def error(span, message) do
      _ = :otel_span.set_status(span_ctx(span), :error, message)
      :ok
    end

    @doc "`params` with the fields the configured propagators write added to its `_meta`."
    @spec inject(map()) :: map()
    def inject(params) do
      case :otel_propagator_text_map.inject([]) do
        [] -> params
        fields -> Map.update(params, "_meta", Map.new(fields), &Map.merge(&1, Map.new(fields)))
      end
    end

    @doc "`fun`, to run in another process with the caller's context current."
    @spec bind((-> result)) :: (-> result) when result: var
    def bind(fun) do
      ctx = :otel_ctx.get_current()

      fn ->
        token = :otel_ctx.attach(ctx)

        try do
          fun.()
        after
          :otel_ctx.detach(token)
        end
      end
    end

    defp start(parent, name, kind, attributes, links) do
      span_ctx =
        :otel_tracer.start_span(parent, tracer(), name, %{
          kind: kind,
          attributes: present(attributes),
          links: :opentelemetry.links(Enum.map(links, &span_ctx/1))
        })

      :otel_tracer.set_current_span(parent, span_ctx)
    end

    defp tracer, do: :opentelemetry.get_application_tracer(__MODULE__)

    # The context a carrier holds, by the configured propagators.
    defp remote(carrier), do: :otel_propagator_text_map.extract_to(:otel_ctx.new(), carrier)

    defp transport(headers) do
      current = :otel_ctx.get_current()
      requested = remote(headers)

      cond do
        span?(current) -> current
        span?(requested) -> requested
        true -> nil
      end
    end

    defp span?(ctx) do
      case span_ctx(ctx) do
        :undefined -> false
        span_ctx -> :otel_span.is_valid(span_ctx)
      end
    end

    defp span_ctx(ctx), do: :otel_tracer.current_span_ctx(ctx)

    defp present(attributes), do: Map.reject(attributes, fn {_, v} -> is_nil(v) end)
  end
else
  defmodule Sake.Trace.OpenTelemetry do
    @moduledoc false
    # Without `opentelemetry_api` there are no spans: `Sake.Trace` checks
    # `enabled?/0` before anything else, and never gets here.

    def server_span(_meta, _headers, _name, _attributes), do: nil
    def child_span(_name, _kind, _attributes), do: nil
    def current, do: nil
    def within(_span, fun), do: fun.()
    def set(span, _attributes), do: span
    def error(_span, _message), do: :ok
    def inject(params), do: params
    def bind(fun), do: fun
  end
end
