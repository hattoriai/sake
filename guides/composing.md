# Composing servers

A large MCP server is easier to own in parts: billing's tools in one
module, support's in another, each with its own tests, middleware and
scopes, served together on one endpoint. `mount` builds one server out
of several.

## Mounting a server

Each part is an ordinary `Sake.Server`, which you can serve on its own
endpoint too:

```elixir
defmodule MyApp.MCP.Billing do
  use Sake.Server,
    name: "billing",
    version: "1.0.0",
    instructions: "Use create_invoice to bill a customer."

  scope "billing:write", "Bill customers"
  tools [MyApp.MCP.Billing.CreateInvoice, MyApp.MCP.Billing.Refund]
  resources [MyApp.MCP.Billing.Invoice, MyApp.MCP.Billing.Dashboard]
  prompts [MyApp.MCP.Billing.Remind]

  middleware :before_call, [MyApp.MCP.Billing.Audit]
end
```

The server you serve mounts the parts:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0", instructions: "My app's tools."

  tools [MyApp.MCP.Search]
  mount MyApp.MCP.Billing, prefix: "billing"
  mount MyApp.MCP.Support, prefix: "support", scope: "support"

  middleware :before_request, [MyApp.MCP.RateLimit]
end
```

`mount` takes two options:

- `prefix:` puts the mounted server's components under a name of their
  own (see below). Without it they keep their names, which must then not
  clash with anything else the server lists.
- `scope:` (one scope or a list) adds required scopes to every component
  mounted, on top of each component's own `scope:`.

Mounting is resolved when `MyApp.MCP` compiles: the mounted server's
components become part of its lists, and a name listed twice anywhere in
them (the server's own components, every mounted server's, at any depth)
is a compile error, as it is within one server. A server mounted inside
a mounted server takes both prefixes.

## Names and URIs

With `prefix: "billing"`:

| The mounted server has | The client sees |
|---|---|
| tool `create_invoice` | tool `billing_create_invoice` |
| prompt `remind` | prompt `billing_remind` |
| resource `invoice://{id}` | resource template `invoice://billing/{id}` |
| resource `billing://terms` | resource `billing://billing/terms` |
| MCP App `ui://dashboard` | MCP App `ui://billing/dashboard` |

Names take the prefix and an underscore, as FastMCP's mounts do. URIs
take the prefix as the first segment after `scheme://`, which keeps the
scheme: an MCP App stays a `ui://` resource, and the tool that shows it
links the renamed URI in its `_meta.ui.resourceUri`. A prefix is 1 to 64
letters, digits, `_` or `-`; a URI without `scheme://` (a `urn:`, say)
cannot take one, and mounting a server that has such a resource under a
prefix is a compile error.

Everything the mounted server's components produce on their side keeps
working with their own names and URIs:

- A template's `list/1` returns the URIs it knows; the client gets them
  under the prefix.
- A read's contents, and the resource links and embedded resources of a
  tool's result, take the prefix when they name one of the mounted
  server's resources. A URI of anything else (`https://...`, another
  server's resource) is left as it is.
- A component sees its own server in `ctx.server`, so
  `Sake.Server.resource_updated(ctx.server, "invoice://7")` and
  `Sake.Server.notify_list_changed(ctx.server, :tools)` work as they did
  before mounting. The broadcasts of a mounted server reach the clients
  of every server that mounts it, with URIs under the prefix: a client
  subscribed to `invoice://billing/7` is told when billing announces
  `invoice://7`, from anywhere.
- Arguments, template parameters and completions are the component's
  own, unchanged.

## What a mounted server brings

- **Instructions** follow the server's own, each under a heading that
  names its prefix (`## billing`), since they speak of the components by
  the names the mounted server gave them.
- **Scopes** declared with `scope` are listed with the server's own (for
  the authorization server's metadata and consent page), and the
  mount's `scope:` is added to them. Each component keeps its `scope:`.
- **Capabilities and extensions** come from the combined lists: a
  mounted task tool turns on the tasks extension, a mounted MCP App the
  apps extension, a subscribable resource `resources.subscribe`. A
  mounted server's `extensions:` merge into the server's, whose own
  settings win.
- **`ttl`**: a mounted server's `ttl` bounds its components' (a list
  that includes one of them has a `ttlMs` no longer than it). The
  server's own `ttl`, `cache_scope` and `page_size` apply to the lists.
- **Tasks** of a mounted task tool are tasks of the server it was
  called through, with the same ownership rules.
- **Authorization** belongs to the endpoint, not the server: the
  endpoint you mount `MyApp.MCP` on decides whether there is a token,
  and the scopes of its components decide what the token must hold.

## Middleware

The server's middleware runs around every component, mounted ones
included. A mounted server's middleware still runs around its own
components, and only those:

- `before_` events run from the outside in: the server's
  `:before_call`, then billing's, then the tool.
- `after_` events run from the inside out: billing's `:after_call`,
  then the server's.
- `:after_list` runs billing's plugs on billing's components first; the
  server's plugs see what they let through, alongside everything else.
  A component billing hides is hidden from the server's clients, in the
  list and for calls, as it is on billing's own endpoint.

Each server's plugs see the components as that server declared them:
billing's `:before_call` gets the tool named `create_invoice`, with
`server: MyApp.MCP.Billing` in the payload, and its `:before_read` the
URI `invoice://7`; the server's plugs get `billing_create_invoice` and
`invoice://billing/7`. So billing's middleware works the same mounted or
not. `:result` is always the result as the client gets it, with renamed
URIs. Assigns flow through all the plugs of a request, whichever server
declared them.

A mounted server's `:before_request` does not run: the request belongs
to the server it arrived at, whose `:before_request` runs for every
request. Put request-wide plugs (a rate limit, say) on the server you
serve.
