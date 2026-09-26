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
`title`), `stream` (see Streaming below), `ttl` (milliseconds; adds
`cacheScope`/`ttlMs` hints to a `resources/read`-shaped result — mostly a
resource concern, but tools accept it too), `meta` (a map merged into the
tool's `_meta`), and `input_schema` (a raw JSON Schema map instead of `arg`
lines, for a shape `arg` cannot express).

List the tool on a server:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  tools [MyApp.MCP.Add, MyApp.MCP.Echo]
end
```

## Arguments

`arg name, type, opts`. Types: `:string`, `:number`, `:integer`,
`:boolean`, `:array` (with `items:`), `:object` (with `properties:`, a
keyword list of `{name, type, opts}` the same shape as top-level `arg`
lines). Common options: `required: true`, `description`, `default`,
`enum` (a list of allowed values), `min`/`max` (numbers: value bounds;
strings and arrays: length bounds), `pattern` (strings, a regex source),
`format` (a JSON Schema format string, e.g. `"date-time"`).

`header: "Name"` (as on `precision` above) additionally accepts the
argument as an HTTP header on the request, named `Name` — a client that
cannot easily set JSON body fields (a thin proxy, a browser extension) can
still supply it. The header name becomes the schema's `x-mcp-header`
extension; names must be unique (case-insensitively) across one tool's
arguments and are only honoured on top-level, `properties`-reachable
fields.

Declared arguments become the map `execute/2` receives, with atom keys
exactly as declared (no camelCase conversion — an argument written
`arg :resourceUri, :string` is looked up on the wire as `"resourceUri"`
and pattern-matched as `%{resourceUri: ...}`).

## Output and results

`output do ... end` declares the tool's `outputSchema` with the same `arg`
syntax; when present, a map result is also mirrored into
`structuredContent`. `execute/2` returns:

- `{:ok, text}` — a single text content block.
- `{:ok, %{...} | [...]}` — JSON-encoded as text, and (if `output` is
  declared) as `structuredContent` too.
- `{:ok, [%Sake.Content{}, ...]}` — full control: `Sake.Content.text/2`,
  `image/3`, `audio/3`, `resource/3` (embedded), `resource_link/2`.
- `{:ok, value, meta: %{...}}` — the three shapes above, plus a `_meta` map
  on the result.
- `{:error, text}` — `isError: true` with one text content block (not a
  JSON-RPC error: the call succeeded, the *tool* failed).

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
are silently dropped.

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
rejected — the modern retry mechanism ties an answer to the exact call it
answers, so a client cannot resume a handler from an unrelated response.

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
