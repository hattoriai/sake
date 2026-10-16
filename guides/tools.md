# Tools

## Declaring a tool

```elixir
defmodule MyApp.MCP.Add do
  use Sake.Tool,
    name: "add",
    description: "Adds two numbers",
    annotations: [read_only: true, idempotent: true]

  arg :a, :number, required: true
  arg :b, :number, required: true
  arg :precision, :integer, header: "Precision", min: 0, max: 10

  output do
    arg :sum, :number, required: true
  end

  @impl true
  def execute(%{a: a, b: b, precision: p}, _ctx) do
    sum = a + b
    {:ok, %{sum: if(p, do: Float.round(sum / 1, p), else: sum)}}
  end
end
```

`use Sake.Tool` options: `name` (default: the module's last segment,
snake-cased — `MyApp.MCP.Add` becomes `"add"`), `title`, `description`,
`icons`, `scope` (a string, or a list — see Scopes below), `annotations`
(`read_only`, `destructive`, `idempotent`, `open_world` — all booleans, plus
`title`), `stream` (see Streaming below), `ttl` (milliseconds; see Caching
below), `meta` (a map merged into the tool's `_meta`), and `input_schema`
(a raw JSON Schema map instead of `arg` lines, for a shape `arg` cannot
express), `task` (`:optional` or `:required`; see `guides/tasks.md`),
and `ui` and `visibility` (the MCP App the host shows with the tool's
result, and who may call the tool; see `guides/apps.md`).

List the tool on a server:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  tools [MyApp.MCP.Add, MyApp.MCP.Echo]
end
```

## Arguments

`arg name, type, opts`. Types:

- `:string`, `:integer`, `:number`, `:boolean`, and `:any` (no type
  constraint).
- `{:array, type}` — a list whose items all have `type`, e.g.
  `{:array, :string}`.
- `{:object, [{name, type, opts}, ...]}` — a nested object; each entry has
  the same shape as a top-level `arg` line, e.g.
  `{:object, [{:city, :string, required: true}, {:zip, :string, []}]}`.
- `{:enum, values}` — a string that must be one of `values`, e.g.
  `{:enum, ["open", "closed"]}`.

Options: `required: true`, `description`, `default`, `min`/`max` (numeric
bounds, for `:integer` and `:number`), `min_length`/`max_length` (string
length bounds), `pattern` (strings, a regex source), `format` (a JSON
Schema format string, e.g. `"date-time"`), and `header` (below).

`header: "Precision"` (as on `precision` above) mirrors the argument into
the `Mcp-Param-Precision` request header, so a gateway can route or
rate-limit on it without reading the body. It is not another way to send
the value: the value still travels in the JSON `arguments`, and the header
must carry the same value. When the body has the argument, a request
without the header is refused (and so is a header whose value differs
from the body's); `Sake.Client` sets these headers itself. The header name
becomes the schema's `x-mcp-header` extension; it applies to `:string`,
`:integer` and `:boolean` arguments reachable through object properties,
and names must be unique (case-insensitively) across one tool.

Declared arguments become the map `execute/2` receives, with atom keys
exactly as declared (no camelCase conversion — an argument written
`arg :resourceUri, :string` is looked up on the wire as `"resourceUri"`
and pattern-matched as `%{resourceUri: ...}`).

## Output and results

`output do ... end` declares the tool's `outputSchema` with the same `arg`
syntax. `execute/2` returns:

- `{:ok, text}` — a single text content block.
- `{:ok, %{...} | [...]}` — a map or a list is sent as JSON text *and* as
  `structuredContent`, whether or not `output` is declared.
- `{:ok, [%Sake.Content{}, ...]}` — full control: `Sake.Content.text/2`,
  `image/3`, `audio/3`, `resource/3` (embedded), `resource_link/2`.
- `{:ok, value, meta: %{...}}` — the three shapes above, plus a `_meta` map
  on the result.
- `{:error, text}` — `isError: true` with one text content block (not a
  JSON-RPC error: the call succeeded, the *tool* failed).
- `{:error, {:missing_capability, capabilities}}` — the tool cannot run
  for this client at all: a `-32021` JSON-RPC error (HTTP 400) whose
  `data.requiredCapabilities` is `capabilities`, e.g.
  `%{"sampling" => %{}}`. Resources' `read/2` and prompts' `get/2` may
  return it too.

## Caching

On the modern protocol, list results carry `ttlMs` and `cacheScope`. The
server's `ttl:` (default five minutes) is the ceiling; a tool, resource or
prompt with its own `ttl:` shortens the `ttlMs` of every list page it
appears on — the page's `ttlMs` is the shortest ttl among the server and
the components on it. A resource's `ttl:` also sets the `ttlMs` of its
`resources/read` result.

## Annotations

`annotations: [read_only: true, destructive: false, idempotent: true,
open_world: false, title: "Add two numbers"]` — advisory hints a client
may use to decide whether to ask before calling a tool, exactly as the
spec defines them; Sake does not enforce any of them itself.

## `x-mcp-header`

See `header:` above — it is the tool-argument half of the same mechanism
`Sake.Plug.Headers` uses on the request side (`mcp-method`, `mcp-name`,
`mcp-param-<n>`, mirroring the JSON-RPC body for transports that inspect
headers before the body, and validated against the body on every request).

## Streaming and `Sake.Progress`

`stream: true` opens a Server-Sent Events response for the call, so the
tool can report progress or log messages as it runs:

```elixir
defmodule MyApp.MCP.Reindex do
  use Sake.Tool, name: "reindex", scope: "issues:write", stream: true

  arg :n, :integer, default: 100

  @impl true
  def execute(%{n: n}, ctx) do
    for i <- 1..n do
      Sake.Progress.report(ctx, i, n, "Indexing #{i}")
    end

    {:ok, "Indexed #{n} issues"}
  end
end
```

`Sake.Progress.report/4` is always safe to call: it is a no-op when the
client sent no `progressToken`, so the same tool code serves both cases.
A request that carries a `progressToken` opens the SSE channel on its own
even without `stream: true`. `Sake.Progress.log(ctx, level, data)` sends a
`notifications/message`, but only once the client has set a log level at
or below `level` (via `logging/setLevel` on a legacy session, or a
per-request `_meta` log level on a modern one) — before that, log calls
are silently dropped. Protocol logging is deprecated as of 2026-07-28:
for new code, `Logger` and OpenTelemetry are the better home for logs
(see `guides/observability.md`).

A `stream: true` tool only actually streams when the call is allowed: a
forbidden call (see Scopes) never opens the SSE response — it comes back
as a plain 403. A scope error on an otherwise-streamed call reaches the
client as an in-stream JSON-RPC error only if the request carried a
`progressToken`; without one, Sake has no open channel to put it on and
falls back to the plain response.

## Elicitation

```elixir
case Sake.Elicit.form(ctx, :who, "Who should be greeted?", %{
       "type" => "object",
       "properties" => %{"name" => %{"type" => "string"}},
       "required" => ["name"]
     }) do
  {:ok, %{"name" => name}} -> {:ok, "Hello, #{name}!"}
  :decline -> {:ok, "No greeting then."}
  :cancel -> {:error, "Cancelled."}
  {:error, :unsupported} -> {:error, "This client does not support elicitation."}
end
```

`Sake.Elicit.url/4` asks the person to open a URL instead (2025-11-25 and
the modern era only).

**No side effects before an elicitation call.** On a modern (stateless)
connection, `Sake.Elicit.form/4` ends the handler the first time it is
called for a given key: Sake replies with an input-required result, and
when the client answers, the *whole handler runs again from the top* —
including any code before the call. A handler with a side effect ahead of
its elicitation calls (an insert, a charge, a second elicitation whose
result depends on state from the first run) would repeat that side effect
on every round-trip. Write elicitation calls at the top of `execute/2`,
before anything else happens.

On a legacy (session-based) connection there is no retry: the call blocks
on the open stream until the client answers, so this constraint does not
apply there — but modern clients are the common case, so write every tool
as if it always will.

On a legacy stream, the elicitation request carries the handler's key in
`_meta["ai.hattori.sake/key"]`, so a client juggling more than one
in-flight question can tell which is which; a client that ignores the key
and answers on the single `_meta`-less legacy pattern is treated as
answering key `"legacy"` (the common case: one question at a time). A
client's `on_input` map (see `guides/client.md`) is keyed the same way.

`inputResponses` sent back without the matching `requestState` are
ignored — the modern retry mechanism ties an answer to the exact call it
answers, so a client cannot resume a handler from an unrelated response.
The handler runs as if nothing had been answered and asks again, as the
specification recommends for a retry that lacks what the server needs. A
`requestState` that fails verification (tampered, expired, or issued for
another call) is refused with `-32602`.

Inside a task (see `guides/tasks.md`), an elicitation waits on the task
for the client's `tasks/update` instead; nothing runs twice there.

## Sampling and roots

A tool can also ask the client's model to complete a conversation, and
ask the client which roots (folders, repositories) it shares:

```elixir
case Sake.Sampling.create_message(ctx, :summary, [user: "Summarize: " <> text],
       max_tokens: 200,
       system_prompt: "You write one-line summaries."
     ) do
  {:ok, %Sake.Sampling.Result{text: summary}} -> {:ok, summary}
  {:error, :unsupported} -> {:error, "This client does not support sampling."}
  {:error, _reason} -> {:error, "The client did not answer."}
end

case Sake.Roots.list(ctx) do
  {:ok, roots} -> {:ok, Enum.map_join(roots, "\n", & &1.uri)}
  {:error, _reason} -> {:error, "No roots."}
end
```

Both travel exactly like `Sake.Elicit`: a multi round-trip request on a
modern connection (so the same rule — no side effects before the call),
a request on the call's stream on a legacy one, and a wait on the task
inside a task. Each is keyed (`:summary` above; `Sake.Roots.list/2`
defaults to `:roots`), and returns `{:error, :unsupported}` when the
client did not declare the capability. `Sake.Sampling.create_message/4`
takes `max_tokens` (required), `system_prompt`, `temperature`,
`stop_sequences`, `model_preferences`, `include_context`, `metadata`, and
on 2025-11-25 and later, `tools` and `tool_choice` (which also need the
client's `sampling.tools` capability). A legacy client that answers with
a JSON-RPC error comes back as `{:error, error}`.

Sampling and roots are deprecated in the 2026-07-28 revision (SEP-2577):
they stay in the specification for at least twelve months, and new
servers are asked to integrate with a model provider directly instead of
sampling, and to take directories and files as tool arguments, resource
URIs or configuration instead of roots. Sake supports both on every
revision because many clients still rely on them; prefer the recommended
route in new tools where you can.

## Several questions at once

Called one after the other, input calls ask one question per round-trip
on a modern connection. `Sake.Input.all/2` asks them together:

```elixir
[name, roots] =
  Sake.Input.all(ctx, [
    &Sake.Elicit.form(&1, :name, "Who are you?", schema),
    &Sake.Roots.list(&1, :roots)
  ])
```

Every unanswered question goes out in one input-required result (and,
inside a task, is pending on the task at once); a question whose
capability the client did not declare comes back
`{:error, :unsupported}` without being asked.

## Before `execute/2`: `prepare/2`

A tool may define `prepare(args, ctx)`, which runs in the request before
`execute/2` and returns the arguments `execute/2` receives (or
`{:error, text}`). It matters for task tools: questions asked in
`prepare/2` travel on the original call, before a task exists — see
`guides/tasks.md`.

## Scopes

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  scope "issues:read", "Read issues"
  scope "issues:write", "Change issues"
  tools [...]
end
```

`scope: "issues:write"` (or `scope: ["issues:read", "issues:write"]`) on a
tool restricts it to a token carrying those scopes. An unauthenticated
endpoint has no token, so every tool is allowed regardless of its
`scope:` — scopes only take effect once `auth: true` is set (see
`guides/authorization.md`). `Sake.Auth.Config.scopes/1` collects every
declared scope, with its description, across the servers an authorization
configuration lists — that list is what a consent page and the
`scopes_supported` discovery field show.
