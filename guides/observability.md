# Observability

Sake reports what it does in two layers. `:telemetry` events are always
there, for metrics and for anything you attach yourself. With
`opentelemetry_api` in your dependencies, Sake also makes OpenTelemetry
spans after the [semantic conventions for
MCP](https://opentelemetry.io/docs/specs/semconv/gen-ai/mcp/), and
carries the trace from a client, through the server, into the tool: an
agent's call, the MCP request, and the Ecto query the tool ran end up in
one trace.

## Telemetry events

| Event | Around | Metadata |
|---|---|---|
| `[:sake, :server, :request, :start \| :stop \| :exception]` | every request `Sake.Plug` or `Sake.Stdio` dispatches | `method`, `component` (the tool or prompt name, or the resource URI), `era`, `protocol_version`, `client_name`; `cancelled` on `:stop` |
| `[:sake, :middleware, :halt]` | a server's middleware refusing a request (see `guides/middleware.md`) | `event`, `plug`, `reason`, `failed`, `server`, `method`, `component`, `era`, `protocol_version`, `client_name` |
| `[:sake, :task, :start \| :stop \| :exception]` | a task's run in the background (see `guides/tasks.md`) | `task_id`, `tool`, `server`; `status` on `:stop` |
| `[:sake, :client, :request, :start \| :stop \| :exception]` | every request `Sake.Client` sends | `method`, `era`, `protocol_version`, `transport` (`:http` or `:stdio`); `error_type` on `:stop`, `nil` on success |

They are `:telemetry.span/3` events: `:stop` carries the `duration` in
native time units. A legacy `initialize` and the items of a 2025-03-26
batch have no event of their own. The `:stop` of `call_tool/3` covers
the whole call, its retries and a task's polls included, which are
events of their own as well.

## OpenTelemetry

### Setting it up in a Phoenix host

Sake only depends on the API, and only optionally: add the SDK, an
exporter, and the instrumentation for the rest of your stack.

```elixir
def deps do
  [
    {:sake, "~> 0.3"},
    {:opentelemetry_api, "~> 1.5"},
    {:opentelemetry, "~> 1.7"},
    {:opentelemetry_exporter, "~> 1.11"},
    {:opentelemetry_phoenix, "~> 2.0"},
    {:opentelemetry_bandit, "~> 0.3"},
    {:opentelemetry_ecto, "~> 1.2"}
  ]
end
```

```elixir
# config/runtime.exs
config :opentelemetry,
  resource: [service: [name: "my_app"]],
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
```

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  OpentelemetryBandit.setup()
  OpentelemetryPhoenix.setup(adapter: :bandit)
  OpentelemetryEcto.setup([:my_app, :repo])

  children = [...]
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

That is all Sake needs: there is nothing to turn on. Without the SDK the
API does nothing, so a library or host that only has `opentelemetry_api`
pays a few function calls per request.

### What Sake records

**The server.** Every request a server serves, on Streamable HTTP (both
eras) and stdio, is a `SERVER` span named `{method} {target}`:
`tools/call search`, `prompts/get triage`, or just `resources/read` and
`tools/list` (a resource URI is too many different names, so it is an
attribute instead). Its parent is the trace context the client put in
the request's `params._meta` (`traceparent`, `tracestate`, `baggage`, read
by your configured propagators). The span that was current when the
request arrived, which is the HTTP server span when you instrument
Phoenix or Bandit, is a link rather than the parent: one MCP request can
take several HTTP requests, and one HTTP stream can carry several MCP
requests. Without a context in `_meta`, the HTTP server span (or the
HTTP request's own `traceparent`) is the parent.

The span is current in the process that runs your component, whether
the request is answered as JSON, on an SSE stream, or over stdio. Spans
your tool makes, directly or through Ecto, Req and the like, nest under
it, the client's baggage is in `OpenTelemetry.Baggage.get_all/0`, and
`Logger` metadata carries `otel_trace_id` and `otel_span_id`.

**Tasks.** A task's run (see `guides/tasks.md`) is an `INTERNAL` span,
`execute_tool {tool}`, the child of the `tools/call` span that started
it, with `gen_ai.tool.call.id` set to the task ID. The task is the rest
of the call the client made, so its work stays in the client's trace,
even though the span can end long after its parent. The `tasks/get`,
`tasks/update` and `tasks/cancel` requests have spans of their own.

**The client.** Every request `Sake.Client` sends, over HTTP or stdio, is
a `CLIENT` span, and carries the current trace context in its `_meta`
(next to the protocol's own fields on the modern protocol; `_meta` is
allowed on every request of the legacy revisions too). A retry after the
authorization flow is the same request under the same span; a retry with
the client's input is a request of its own, under the span of the one it
answers. The span of `call_tool/3` covers the whole call, so a tool call
is one subtree however the server ran it:

```
agent                                  (your span)
└─ tools/call export        CLIENT     Sake.Client
   ├─ tools/call export     SERVER     the server answers with a task
   │  └─ execute_tool export INTERNAL  the task's run
   │     └─ SELECT ...                 Ecto, inside the tool
   ├─ tasks/get             CLIENT
   │  └─ tasks/get          SERVER
   └─ tasks/get             CLIENT
      └─ tasks/get          SERVER
```

**Attributes.** `mcp.method.name`, `mcp.protocol.version`,
`jsonrpc.request.id`, `gen_ai.tool.name` and `gen_ai.operation.name`
(`execute_tool`) on a tool call, `gen_ai.prompt.name`, `mcp.resource.uri`
on `resources/read`, `resources/subscribe` and `resources/unsubscribe`,
`mcp.session.id` on a legacy session, `network.transport` (`tcp` or
`pipe`), and `network.protocol.name` and `network.protocol.version`
(HTTP), `client.address` on the server, `server.address` and
`server.port` on the client.

**Errors.** A JSON-RPC error sets `rpc.response.status_code`. On the
client every error code is an error: the span's status is `ERROR`, with
the error's message, and `error.type` is the code. On the server, the
codes that mean the caller sent something it could not serve (-32700,
-32600, -32601, -32602, which is also an unknown tool, and -32002) are
not the server's errors and leave the status alone. A tool result with
`isError` is `error.type` `tool_error` and status `ERROR` on both sides.
A client request that fails without an answer (a refused connection, a
timeout) has `error.type` set to the exception's module or the reason,
like `Req.TransportError` or `timeout`.

**Middleware.** A request the server's middleware refused (see
`guides/middleware.md`) has `sake.middleware.event` and
`sake.middleware.plug` on its span, the event and the module that
halted; its status follows the error the client got, as above.

### Configuration

```elixir
config :sake, :opentelemetry, record_content: true
```

`record_content: true` adds what the conventions leave opt-in because it
may be sensitive: a tool call's arguments (`gen_ai.tool.call.arguments`)
and result (`gen_ai.tool.call.result`), as JSON, and a prompt's arguments
(`gen_ai.prompt.variable.<name>`). By default none of them is recorded.

`enabled: false` turns Sake's spans off, and with them the trace context
in `_meta`; your own spans are untouched.

### Where Sake differs from the conventions

The conventions are in development, and Sake follows them as written
except here:

- The span of `call_tool/3` lasts until the tool's result is in, not
  until the first answer: with retries or a task, the requests that
  follow are its children.
- The server's `mcp.session.id` is the legacy session's identity (its
  nonce), which stays the same while the `Mcp-Session-Id` value is
  re-minted; the client records the `Mcp-Session-Id` it holds. The
  modern protocol has no sessions.
- Notifications have no spans, in either direction, and neither have
  the requests a server sends a legacy client on a stream (elicitation,
  sampling, roots) nor the items of a 2025-03-26 batch. A
  `subscriptions/listen` span lasts as long as its stream.
- There are no OpenTelemetry metrics (see below).

### Metrics

The OpenTelemetry metrics API for Erlang and Elixir is not part of
`opentelemetry_api` yet, so Sake records no metrics itself. The
conventions' operation durations follow from the telemetry events, for
instance with `Telemetry.Metrics`:

```elixir
distribution("mcp.server.operation.duration",
  event_name: [:sake, :server, :request, :stop],
  measurement: :duration,
  unit: {:native, :second},
  tags: [:method, :protocol_version]
),
distribution("mcp.client.operation.duration",
  event_name: [:sake, :client, :request, :stop],
  measurement: :duration,
  unit: {:native, :second},
  tags: [:method, :error_type]
)
```

The conventions' session durations have nothing to measure in Sake: a
modern server keeps no sessions, and a legacy session ends when its
client stops using it, without telling the server.

## Logging

MCP 2026-07-28 deprecates protocol logging, `notifications/message`
(SEP-2577), in favour of standard error on stdio and OpenTelemetry for
structured observability. `Sake.Progress.log/3` still sends it to a
client that asks for it, on both eras, and keeps doing so while the
protocol has it. For anything new, log with `Logger`:

- On stdio, `Sake.Stdio` moves the default `Logger` handler to standard
  error (see `guides/stdio.md`), which is where the specification wants
  a server's logs. Configure it in a release, which logs while it boots;
  the OpenTelemetry SDK does too.
- With OpenTelemetry, a log line written while a span is current has
  the trace and span IDs in its `Logger` metadata (`otel_trace_id`,
  `otel_span_id`), so any log backend that keeps them ties the line to
  the request, and an OpenTelemetry logs pipeline can ship them as the
  trace's logs.

What a log message told the person at the client (that a step began,
how far a long call got) is often progress: `Sake.Progress.report/4`
stays, and in a task it sets the task's status message.
