# Middleware

Middleware is your code around every MCP call, written once instead of
in each tool. Use it to record who called which tool with which
arguments, to rate-limit a principal, to hide tools a plan does not
include, to put the tenant into the arguments, to redact results, and
to time calls. `:telemetry` observes what Sake does; middleware can also
decide what happens and change it.

Middleware is modelled on Lotus's, and so on Plug: a module with
`init/1` and `call/2`, run in pipelines keyed by named events.

## Declaring middleware

A middleware module implements the `Sake.Middleware` behaviour:

```elixir
defmodule MyApp.MCP.Audit do
  @behaviour Sake.Middleware

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{tool: tool, arguments: args, ctx: ctx} = payload, _opts) do
    MyApp.Audit.record(ctx.scope, tool.name, args)
    {:cont, payload}
  end
end
```

`call/2` gets the event's payload and returns `{:cont, payload}` to go
on, with the payload changed or not, or `{:halt, reason}` to refuse the
request.

The server declares its middleware by event:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  tools [MyApp.MCP.Search, MyApp.MCP.Export]

  middleware :before_request, [{MyApp.MCP.RateLimit, per_minute: 60}]
  middleware :after_list, [MyApp.MCP.Plans]
  middleware :before_call, [MyApp.MCP.Tenant, MyApp.MCP.Audit]
  middleware :after_call, [MyApp.MCP.Redact]
end
```

A plug is `Module` or `{Module, opts}`. The plugs of an event run in the
order they are declared, and an event can be declared more than once:
the later plugs run after the earlier ones.

`init/1` is optional. Like a Plug's, it runs once, when the server
module compiles, and what it returns is stored in the module: return
plain data (no functions, PIDs or references), and read anything that
changes at runtime, such as application configuration, in `call/2`.

Middleware belongs to the server, not to the endpoint, so it runs
whatever carries the request: `Sake.Plug` (with or without an SSE
stream), `Sake.Stdio` and `Sake.Test`, on the modern protocol and on
the handshake-era revisions alike. An application that serves several
servers gives each its own middleware; a server mounted inside another
keeps its middleware around its own components, inside the parent's
(see `guides/composing.md`).

## Events

Every payload has these keys:

| Key | Value |
|---|---|
| `:server` | the server module |
| `:method` | the JSON-RPC method, `"tools/call"` for instance |
| `:ctx` | the request's `Sake.Context`: the principal in `ctx.scope`, the token in `ctx.token` and `ctx.scopes`, `ctx.era`, `ctx.client_info` |
| `:assigns` | a map that carries decisions to the later plugs (see below) |

And, by event:

| Event | Runs | Also in the payload | Sake reads back |
|---|---|---|---|
| `:before_request` | before every request, any method, except the legacy `initialize` | `:params` | `:assigns` |
| `:after_list` | after `tools/list`, `resources/list`, `resources/templates/list` and `prompts/list` have applied scopes and MCP Apps visibility, before paging; and before any call reaches a component | `:kind` (`:tools`, `:resources`, `:prompts`), `:items` | `:items` |
| `:before_call` | before a tool runs, after its arguments were validated | `:tool`, `:arguments` | `:arguments`, `:assigns` |
| `:after_call` | after the tool returned, or after its task ended | `:tool`, `:arguments`, `:result` | `:result` |
| `:before_read` | before a resource is read | `:resource`, `:uri`, `:params` | `:params`, `:assigns` |
| `:after_read` | after the resource was read | `:resource`, `:uri`, `:params`, `:result` | `:result` |
| `:before_get` | before a prompt is rendered, after its arguments were checked | `:prompt`, `:arguments` | `:arguments`, `:assigns` |
| `:after_get` | after the prompt was rendered | `:prompt`, `:arguments`, `:result` | `:result` |

- `:tool`, `:resource` and `:prompt` are the component's spec
  (`Sake.Tool.Spec`, `Sake.Resource.Spec`, `Sake.Prompt.Spec`), with its
  `name` (a resource: `uri`), `scopes` and `module`. `:items` is a list
  of them.
- `:arguments` is the map the component receives, with atom keys.
  `:params` is a resource template's parameters, the map `read/2` gets.
- `:result` is the result as the client gets it, with string keys: a
  `CallToolResult` (`"content"`, `"structuredContent"`, `"isError"`), a
  `ReadResourceResult` (`"contents"`) or a `GetPromptResult`
  (`"messages"`, `"description"`).

### The contract

- **Sake reads back only the last column.** A change to any other key
  is ignored: a `:before_call` plug can rewrite the arguments, not the
  tool. A plug that continues with one of those keys of the wrong shape
  (arguments that are not a map, items that are not a list) fails the
  request, as one that raises does.
- **Payload keys are additive.** A release may add a key; it does not
  remove or rename one. Match on the keys you use.
- **Halting is final.** A halt answers the request: the later plugs of
  the event, the later events and the component do not run.
- **A `before_` event decides on what a client sent, an `after_` event
  on what it gets.** A call that fails validation never reaches
  `:before_call` (the client gets the tool error with the validation
  messages); a call `:before_call` refuses never reaches `:after_call`.

## Assigns

`:assigns` carries what a `before_` plug decided to the later plugs of
the same request and to the component, which reads it as
`ctx.assigns`. It starts as `%{}` at `:before_request`; the `before_`
events carry it forward, and the `after_` events read it. Put your keys
into the map rather than replace it, so plugs do not remove each other's
keys.

```elixir
defmodule MyApp.MCP.Grants do
  def call(%{tool: tool, ctx: ctx, assigns: assigns} = payload, _opts) do
    case MyApp.Grants.resolve(ctx.scope, tool.name) do
      {:ok, grants} -> {:cont, %{payload | assigns: Map.put(assigns, :grants, grants)}}
      :error -> {:halt, {:forbidden, ["#{tool.name}:use"]}}
    end
  end
end

defmodule MyApp.MCP.ColumnFilter do
  def call(%{result: result, assigns: %{grants: grants}} = payload, _opts),
    do: {:cont, %{payload | result: MyApp.Grants.restrict(result, grants)}}
end
```

Assigns belong to one request. A tool that asks the client for input
on the modern protocol answers with `input_required`, and the client
retries with the answers: that retry is a new request, so it starts
again from `%{}` and runs `:before_request` and `:before_call` again.
A rate limiter therefore counts each round. On a legacy session the
question travels on the same request, which runs the events once.

## Halting

The reason a plug halts with decides what the client gets. Only these
say anything; any other reason is refused without saying why, so an
internal reason (an exception, a database error, a policy name) never
reaches the client.

| Reason | The client gets |
|---|---|
| `:not_found` | what it would get if the component (or, for other methods, the method) did not exist: `-32602` "Unknown tool: export", "Unknown prompt: …", the era's resource-not-found error, `-32601` "Method not found" |
| `{:forbidden, scopes}` | the insufficient-scope refusal: HTTP 403 with a `WWW-Authenticate` challenge naming `scopes` (on an endpoint with authorization), so the client can step up |
| `:forbidden` | HTTP 403, `-32600` "Forbidden", with no challenge: no token would lift it |
| `{:error, message}` | `-32600` with `message` |
| `{:tool_error, message}` | on `:before_call` and `:after_call`, a tool result with `isError: true` and `message`, which the model reads and can act on; elsewhere, as `{:error, message}` |
| anything else | `-32600` "Request refused" |

A plug that raises, throws or exits counts as a halt too: the error is
logged with the plug's name and event, the client gets `-32603` "The
request failed.", and the request's process carries on. Under
`Sake.Test`, which re-raises a component's exceptions by default, the
plug's exception reaches the test the same way (`reraise: false` turns
it into the error a client gets).

Off HTTP (stdio, `Sake.Test`), a 403 is the JSON-RPC error alone;
`Sake.Test` returns `{:error, {:insufficient_scope, challenge}}` for
`{:forbidden, scopes}` and `{:error, {:http, 403, body}}` for
`:forbidden`, as `Sake.Client` does against an endpoint. A call the
client asked to stream (with a progress token, for one) has already
started its SSE stream when the tool's middleware runs, so its refusal
is the stream's one message, as any other error of a streamed call is.

## Hiding components

An `:after_list` plug filters what a principal sees:

```elixir
defmodule MyApp.MCP.Plans do
  @behaviour Sake.Middleware

  @impl true
  def call(%{items: items, ctx: %{scope: account}} = payload, _opts),
    do: {:cont, %{payload | items: Enum.filter(items, &MyApp.Plans.includes?(account.plan, &1))}}
end
```

The same plug decides the calls. Before a `tools/call`, a
`resources/read`, a `prompts/get`, a `completion/complete` or a legacy
`resources/subscribe` reaches a component, Sake runs the `:after_list`
plugs again with `:items` holding only that component and `:method`
naming the request. A component they drop is answered as one that does
not exist ("Unknown tool: export"), so a client cannot call what it
cannot list, and cannot tell a hidden tool from a missing one. A
`subscriptions/listen` stream leaves a hidden resource out of the
`resourceSubscriptions` it honours, as it does one the token's scopes do
not allow and a URI that names no resource.

For this to hold, write `:after_list` plugs as filters: decide each item
on its own, from the item and the request. A plug may drop and reorder
items, or change them (a description, say); a component it adds that
the server did not offer is dropped, since no call could reach it.
`:kind` is `:resources` for both resource lists; the specs of templates
have `template: true`.

Sake applies its own rules first: the plugs never see a component the
token's scopes or MCP Apps visibility exclude. With any `:after_list`
plug, list results carry `cacheScope: "private"`: the list now depends
on who asks, and a shared cache must not hand one principal's list to
another. With `:before_read` or `:after_read` plugs, so do the results
of `resources/read`.

## Examples

### An audit log

Record every tool call, its arguments, and how it ended:

```elixir
defmodule MyApp.MCP.Audit do
  @behaviour Sake.Middleware

  @impl true
  def call(%{tool: tool, arguments: args, result: result, ctx: ctx} = payload, _opts) do
    MyApp.Repo.insert!(%MyApp.AuditEntry{
      principal_id: ctx.scope.id,
      tool: tool.name,
      arguments: args,
      error: result["isError"],
      client: ctx.client_info["name"]
    })

    {:cont, payload}
  end
end
```

```elixir
middleware :after_call, [MyApp.MCP.Audit]
```

`:after_call` sees every call that ran, failed tool results included.
A refused call never gets there; to record refusals too, attach to the
`[:sake, :middleware, :halt]` telemetry event (see "Observing" below),
which carries the plug, the reason and the request.

### A rate limit

`:before_request` runs for every method, before anything else:

```elixir
defmodule MyApp.MCP.RateLimit do
  @behaviour Sake.Middleware

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :per_minute)

  @impl true
  def call(%{ctx: ctx} = payload, per_minute) do
    case MyApp.RateLimiter.hit("mcp:#{ctx.scope.id}", :timer.minutes(1), per_minute) do
      {:allow, _count} -> {:cont, payload}
      {:deny, retry_ms} -> {:halt, {:error, "Rate limit exceeded, retry in #{div(retry_ms, 1000)}s"}}
    end
  end
end
```

To limit only tool calls, declare it on `:before_call` instead, or match
`%{method: "tools/call"}`.

### Feature flags and plans

Hide what a plan does not include with an `:after_list` plug (see
"Hiding components" above): the list and the calls agree from that one
plug. To list a tool but explain why it cannot run, so that the model
can tell the person, refuse at `:before_call` with a tool error
instead:

```elixir
defmodule MyApp.MCP.ProTools do
  @behaviour Sake.Middleware

  @pro ~w(export bulk_update)

  @impl true
  def call(%{tool: %{name: name}, ctx: %{scope: account}} = payload, _opts)
      when name in @pro do
    if MyApp.Flags.enabled?(:pro_tools, account),
      do: {:cont, payload},
      else: {:halt, {:tool_error, "#{name} is part of the Pro plan."}}
  end

  def call(payload, _opts), do: {:cont, payload}
end
```

### Putting the tenant into the arguments

A `:before_call` plug may change the arguments, and the tool, its
`prepare/2` and a task all get the changed ones. Arguments are
validated before the plug runs, so a key the plug adds need not be in
the tool's schema, and the client never sees it there:

```elixir
defmodule MyApp.MCP.Tenant do
  @behaviour Sake.Middleware

  @impl true
  def call(%{ctx: %{scope: %{org_id: org_id}}} = payload, _opts) do
    payload = %{payload | assigns: Map.put(payload.assigns, :org_id, org_id)}

    case payload do
      %{arguments: args} -> {:cont, %{payload | arguments: Map.put(args, :org_id, org_id)}}
      %{params: params} -> {:cont, %{payload | params: Map.put(params, :org_id, org_id)}}
    end
  end
end
```

```elixir
middleware :before_call, [MyApp.MCP.Tenant]
middleware :before_read, [MyApp.MCP.Tenant]
```

The plug overwrites whatever the client sent under that key. Components
can read the same value from `ctx.assigns.org_id`.

### Redacting results

An `after_` plug may change the result, which is the wire result:

```elixir
defmodule MyApp.MCP.Redact do
  @behaviour Sake.Middleware

  @impl true
  def call(%{result: result} = payload, _opts), do: {:cont, %{payload | result: redact(result)}}

  defp redact(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, redact(v)} end)
  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  defp redact(text) when is_binary(text), do: MyApp.PII.mask(text)
  defp redact(other), do: other
end
```

```elixir
middleware :after_call, [MyApp.MCP.Redact]
middleware :after_read, [MyApp.MCP.Redact]
middleware :after_get, [MyApp.MCP.Redact]
```

A tool that returns structured content has it twice, as
`"structuredContent"` and as its JSON text in `"content"`; redact both,
as this plug does by walking the whole result.

### Timing calls

Middleware sees only the calls its events cover, and not the ones a
plug before it refused, so measure with telemetry: the
`[:sake, :server, :request, :stop]` event carries every request's
duration, refused ones too (see `guides/observability.md`). When a
timing belongs in your own records, a `:before_call` plug can put the
start in the assigns and an `:after_call` plug read it:

```elixir
def call(%{assigns: assigns} = payload, :start),
  do: {:cont, %{payload | assigns: Map.put(assigns, :started, System.monotonic_time())}}

def call(%{assigns: %{started: started}, tool: tool} = payload, :stop) do
  MyApp.Metrics.record(tool.name, System.monotonic_time() - started)
  {:cont, payload}
end
```

```elixir
middleware :before_call, [{MyApp.MCP.Timing, :start}]
middleware :after_call, [{MyApp.MCP.Timing, :stop}]
```

## How middleware meets the rest of Sake

- **Tasks.** `:before_call` runs in the `tools/call` request, before the
  task exists: a refusal creates no task. `:after_call` runs when the
  task's tool returns, with the assigns of the request that started it,
  and its result is the one `tasks/get` hands out. A halt there fails
  the task with the halt's error, or, for `{:tool_error, message}`,
  completes it with that tool error. A task that fails or is cancelled
  has no result, and no `:after_call`.
- **Input requests.** Each modern retry is a new request (see
  "Assigns"). A `before_` plug runs before the component, so it can ask
  the client for input itself (`Sake.Elicit`), as a tool's `prepare/2`
  can.
- **Scopes.** Sake's scope checks come first: a call the token's scopes
  do not allow is refused before `:before_call` runs.
- **MCP Apps.** A tool only an app may call is hidden from a client
  without apps before `:after_list` runs; the plugs see what the client
  could see.
- **Completions and subscriptions.** A prompt or resource that
  `:after_list` hides cannot be completed, subscribed to (legacy), or
  followed on a `subscriptions/listen` stream (modern). `:before_request`
  runs for a `subscriptions/listen` request too.

## Observing

Middleware decides; telemetry observes. `[:sake, :server, :request]`
brackets every request, refused or not. A halt also emits
`[:sake, :middleware, :halt]`, where the plug ran, with:

| Metadata | Value |
|---|---|
| `event`, `plug` | the event and the module that halted |
| `reason` | the reason it gave (for a failure, the exception) |
| `failed` | `true` when the plug raised, threw, exited or answered with the wrong shape |
| `server`, `method`, `component` | the request, and the tool or prompt name or resource URI |
| `era`, `protocol_version`, `client_name` | as on `[:sake, :server, :request]` |

With OpenTelemetry, the request's span gets `sake.middleware.event` and
`sake.middleware.plug`. Its status follows the answer the client got:
a refusal (`-32600`, `-32602`) is the caller's error and leaves the
status alone, a plug's failure (`-32603`) and a tool error set `ERROR`.

## Testing middleware

`Sake.Test` runs the server's middleware as any transport does, so
test it through the server, with the principal your plugs read:

```elixir
test "a free account does not see export" do
  client = connect(MyApp.MCP, scope: account_fixture(plan: :free))

  assert {:ok, tools} = list_tools(client)
  refute "export" in Enum.map(tools, & &1.name)
  assert {:error, {:rpc, %{"message" => "Unknown tool: export"}}} = call_tool(client, "export")
end
```
