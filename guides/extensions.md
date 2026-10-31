# Extensions

MCP grows through extensions (SEP-2133): a set of methods, settings and
notifications under an identifier such as `com.example/widgets`, which
a server advertises in its capabilities and a client declares in its
own when it wants them. `Sake.Extension` implements one on a Sake
server, without forking Sake or writing a transport. Sake's own Skills
support (`guides/skills.md`) is served through the same machinery.

## An extension

```elixir
defmodule Widgets.MCP.Extension do
  use Sake.Extension, id: "com.example/widgets", scope: "widgets:read"

  method "widgets/list"
  method "widgets/delete", scope: "widgets:write"
  notification "notifications/widgets/changed"

  @impl true
  def settings(_server), do: %{"maxPageSize" => 50}

  @impl true
  def handle("widgets/list", params, ctx) do
    page = Widgets.page(ctx.scope, params["cursor"])
    {:ok, Sake.Extension.cacheable(%{"widgets" => page.items, "nextCursor" => page.next}, ctx)}
  end

  def handle("widgets/delete", %{"id" => id}, ctx) do
    :ok = Widgets.delete(ctx.scope, id)
    Sake.Extension.notify(ctx.server, __MODULE__, "notifications/widgets/changed", %{"id" => id})
    {:ok, %{}}
  end

  def handle("widgets/delete", _params, _ctx),
    do: {:error, -32602, "widgets/delete needs an id"}
end
```

A server serves it by listing it:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  tools [MyApp.MCP.Search]
  extensions [Widgets.MCP.Extension]
end
```

`use Sake.Extension` options:

- `id:` (required): `vendor-prefix/name`. Identifiers under
  `io.modelcontextprotocol/` are the protocol's own.
- `scope:` and `authentication:`: what every method requires, checked
  as for a tool. A token without the scopes gets the 403 that asks it to
  step up.
- `client:`: `:optional`, the default, lets any client call the
  methods. `:required` answers a client that did not declare the
  extension with `-32021` (missing capability), naming it.
- `since:`: the oldest revision the extension is served on (say
  `"2026-07-28"`). On an older one it is not advertised and its methods
  are unknown.
- `result_types:`: `resultType`s of the extension's own (below).

`method name, scope: ..., authentication: ...` declares a method; its
options add to the extension's. `notification name` declares a
notification the extension sends. `settings/1` (optional, `%{}` by
default) is advertised under the identifier, in `server/discover` on
2026-07-28 and in `initialize` on a legacy session:

```json
"extensions": {"com.example/widgets": {"maxPageSize": 50}}
```

## Handling a method

`handle/3` gets the method's name, its params as the client sent them
(string keys, `_meta` included) and the request's `Sake.Context`
(`ctx.scope`, `ctx.token`, `ctx.client_capabilities`). It returns:

- `{:ok, result}`: the result map. On 2026-07-28, Sake adds
  `resultType: "complete"` and the server info in `_meta`, as for a core
  method. `Sake.Extension.cacheable(result, ctx, ttl: ms)` adds `ttlMs`
  and `cacheScope` from the server's settings, for a result a client may
  cache.
- `{:error, code, message}` or `{:error, code, message, data}`: a
  JSON-RPC error. Use `-32602` for bad params.
- `{:error, {:missing_capability, %{...}}}`: `-32021`, for a request the
  client's capabilities cannot be served for.

An exception in `handle/3` is logged and answered with `-32603` "The
request failed.". So is anything else `handle/3` returns, with a log
line saying what it returned.

An extension that defines a result of its own (a job to poll, say)
names its `resultType` in `result_types:` and returns it. Sake sends
it only to a client that declared the extension, the only one that can
read it. To any other client it is a `-32603`, and a log line says why.

`Sake.Extension.declared?(ctx, id)` tells whether the client declared
an extension, for a method that answers differently when it did.

## What a request goes through

An extension method is dispatched like a core one:

- **Endpoints:** `Sake.Plug` over HTTP (on both eras), `Sake.Stdio`,
  and `Sake.Test`'s in-memory client.
- **HTTP headers:** the `Mcp-Method` header must name the method, as
  for any request. Extension methods don't use `Mcp-Name`.
- **Middleware:** the `:before_request` middleware. Its payload has
  `method` and `params`, so a rate limit, an audit log or a refusal
  covers extension methods too.
- **Authorization:** the method's scopes and authentication, checked as
  a tool's are, with the same 403 and 401 step-up challenges.
- **Telemetry and tracing:** the `[:sake, :server, :request]` span, and
  the server span with the method's name (see
  `guides/observability.md`).

A method of the protocol (`tools/list`, `resources/read`, `skills/get`,
`tasks/get` and the rest), one under `notifications/`, or one another
listed extension declares cannot be declared: it is a compile error, as
are two extensions with the same identifier, or an identifier also in
the server's `extensions:` option.

## Notifications

`Sake.Extension.notify(server, extension, method, params)` broadcasts
one of the extension's declared notifications to the server's clients,
and to other nodes when Sake has a pubsub (see `guides/clustering.md`).

- **On 2026-07-28:** a client gets them on a `subscriptions/listen`
  stream whose `notifications` filter names the extension:

  ```json
  {"method": "subscriptions/listen",
   "params": {"notifications": {"com.example/widgets": true}}}
  ```

  The acknowledgement lists the identifier only for an extension that
  declares notifications. Each notification carries the stream's
  `subscriptionId` in `_meta`, as the core ones do.
- **On a legacy session:** the session's stream (the HTTP GET stream,
  or stdio) gets them all, since a legacy client has no filter to ask
  with.

## Mounting and proxies

A mounted server's extensions are served by the server that mounts it.

- **Method names:** the protocol's, so a prefix does not rename them.
  Two different extensions with the same method, from any mounted
  server, are a compile error.
- **One extension mounted twice:** an extension listed by two mounted
  servers (one library mounted twice, say) is served once, by the first
  mount.
- **Context:** `handle/3` runs with its own server in `ctx.server` and
  the mounts' prefixes in `ctx.prefixes`.
- **Authorization:** the mount's `scope:` and the parent's
  `authentication:` apply to its methods.
- **Settings:** `settings/1` gets the extension's own server.

A `Sake.Proxy` forwards no extension method. It advertises only the
extensions it can actually serve:

- **Sake's own:** tasks, MCP Apps, and with `skills: true`, skills.
- **Its own module's:** extensions the proxy module lists itself.

An upstream's other extensions are not advertised, and their methods
are answered as unknown. A gateway that needs one lists an extension
of its own that calls the upstream.

## Shipping an extension in a package

An extension is ordinary Elixir code that depends on Sake, so it can
live in a package of its own:

```elixir
# the extension package's mix.exs
{:sake, "~> 0.5"}
```

Hosts that do not list the extension pay nothing for it. A library
whose MCP support is optional wraps the module in
`if Code.ensure_loaded?(Sake.Extension)`, as `guides/libraries.md`
describes for servers.

The extension's identifier and method names are its public API: a
client that declared `com.example/widgets` expects them to stay.
Version a breaking change with a new identifier, or a version in
`settings/1`.

## Testing

`Sake.Test` connects a client to a server in memory. `Sake.Client.request/4`
sends any method, an extension's included:

```elixir
test "widgets/list lists the principal's widgets" do
  client = connect(MyApp.MCP, scope: user, scopes: ["widgets:read"])
  session = Sake.Test.session(client)

  assert session.server_capabilities["extensions"]["com.example/widgets"] ==
           %{"maxPageSize" => 50}

  assert {:ok, %{"widgets" => [_ | _]}, _session} =
           Sake.Client.request(session, "widgets/list", %{})
end

test "widgets/delete needs the write scope" do
  client = connect(MyApp.MCP, scope: user, scopes: ["widgets:read"])

  assert {:error, {:insufficient_scope, %{scope: ["widgets:read", "widgets:write"]}}, _} =
           Sake.Client.request(Sake.Test.session(client), "widgets/delete", %{"id" => "1"})
end
```

The in-memory client re-raises an exception from `handle/3`, so a test
sees it. To test what a client gets for one (`-32603`), send the
request through the endpoint with `plug:` (see `guides/testing.md`). A
client that declares the extension passes it in `capabilities:` of
`Sake.Client.connect/2`, or, for one request on 2026-07-28, in the
request's `_meta`.
