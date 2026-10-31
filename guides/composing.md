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

`mount` takes these options:

- `prefix:` puts the mounted server's components under a name of their
  own (see below). Without it they keep their names, which must then not
  clash with anything else the server lists.
- `scope:` (one scope or a list) adds required scopes to every component
  mounted, on top of each component's own `scope:`.
- `only:` or `except:` mounts some of the mounted server's components:
  only those listed, or all but those (see below).

## Mounting some of a server

A server from a library, or another team's, may list components you
do not want to serve. `except:` leaves them out; `only:` takes the ones
you name and nothing else:

```elixir
mount MyApp.MCP.Billing, prefix: "billing", except: [MyApp.MCP.Billing.Refund]
mount MyApp.MCP.Support, prefix: "support", only: ["open_ticket", "ticket://{id}"]
```

Each entry names a component as the mounted server declares it, before
any prefix: its module, a tool or prompt name, or a resource URI (a
template's too). A name that a tool and a prompt share names both. A left
out component is not listed, called, read or got through the server, and
counts for nothing else (the capabilities, the tasks and MCP Apps
extensions it would turn on, a list's `ttlMs`); the mounted server
serves it as before on an endpoint of its own.

Both options are checked when the server compiles:

- an entry that names nothing the mounted server lists is an error, so a
  typo in `except:` cannot leave serving what it meant to hide;
- a kept tool that shows an MCP App left out is an error, as it is for
  any server that does not list a tool's UI;
- `only:` and `except:` together are an error;
- a server that lists a proxy's upstream components cannot be filtered,
  since those are known only at runtime: mount the proxy's server with
  a middleware that filters the list instead (`guides/middleware.md`).

The scopes the mounted server declares are still listed, for the
authorization server's metadata and consent page, whichever of its
components are mounted.

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
| skill `skill://refunds/SKILL.md` | skill `skill://billing/refunds/SKILL.md` |

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
- A skill's manifest moves with it, every file's URI under the prefix,
  with the same digests: the files are the same bytes (see
  `guides/skills.md`).

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

## Proxying another server

`Sake.Proxy` exposes another MCP server's tools, resources and prompts
through your endpoint, forwarding every call with `Sake.Client`. The
proxy adds what the upstream lacks: your login and scopes, middleware
(access control, audit, rate limits), one approved endpoint in front of
many third-party servers.

```elixir
defmodule MyApp.MCP.GitHub do
  use Sake.Proxy,
    name: "github",
    version: "1.0.0",
    upstream: "https://api.githubcopilot.com/mcp/",
    tools: [except: ["delete_repository"]],
    scope: "github",
    scopes: %{"create_issue" => "github:write"}

  @impl Sake.Proxy
  def credentials(ctx) do
    case MyApp.Accounts.github_token(ctx.scope) do
      {:ok, token} -> {:bearer, token}
      :error -> {:error, "Connect your GitHub account first."}
    end
  end
end
```

A proxy is a `Sake.Server`, so it is served and mounted as any other:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"

  tools [MyApp.MCP.Search]
  mount MyApp.MCP.Billing, prefix: "billing"
  mount MyApp.MCP.GitHub, prefix: "github"
  mount MyApp.MCP.Linear, prefix: "linear"
end
```

It keeps its upstream sessions in a process of its own: add it to the
supervision tree, after `Sake`. Any option may be given there instead,
where it overrides the one given to `use` (the upstream's URL usually
comes from the environment):

```elixir
children = [
  {Sake, secret_key_base: ...},
  {MyApp.MCP.GitHub, upstream: System.fetch_env!("GITHUB_MCP_URL")}
]
```

`upstream:` is the URL of a Streamable HTTP server, or `{:stdio,
command, args}` for a server the proxy starts as a subprocess (with
`connect: [env: ..., cd: ..., stderr: :ignore]`). The proxy speaks the
upstream's era, whichever it is, to clients of either era.

### What it exposes

- `tools:` and `prompts:` take `true` (the default), `false`, or
  `[only: names]` or `[except: names]`, by the upstream's names;
  `resources:` takes `true` or `false`, and `skills:` `true` or `false`
  (the default): with `true`, the upstream's skills are passed on (see
  "Behind a proxy" in `guides/skills.md`).
- `scope:` adds required scopes to every proxied component, and
  `scopes:` maps an upstream tool or prompt name to more. They gate the
  proxied components as a local component's `scope:` does: a token
  without them gets the 403 that asks the client to step up, with your
  authorization server.
- The proxy's own middleware, and that of every server that mounts it,
  runs around the proxied components as around local ones. A proxied
  call's `:arguments` (and a proxied prompt's) are what the client sent,
  with string keys: the upstream validates them. An `:after_list` plug
  decides what each principal may see and call from the upstream:

  ```elixir
  defmodule MyApp.MCP.GitHubAccess do
    def call(%{items: items, ctx: %{scope: user}} = payload, _opts),
      do: {:cont, %{payload | items: Enum.filter(items, &MyApp.Policy.allows?(user, &1.name))}}
  end
  ```

- A proxy may declare tools of its own too. A proxied component whose
  name is already taken, by the proxy's own or by any other component of
  the server it is mounted in, is left out: an upstream never shadows a
  local component.

What an upstream sends is untrusted: a definition that is not shaped as
its kind is left out, a tool's name must be one Sake accepts, and no
name the upstream sends becomes an atom.

### Credentials

Without a `credentials/1` callback, the proxy calls the upstream with
what `connect:` gives it: nothing, a fixed token
(`connect: [headers: [{"authorization", "Bearer ..."}]]`), or the
client's own authorization flow, such as a machine client's (see
`guides/client.md`):

```elixir
connect: [auth: [grant: :client_credentials, client_id: "my-app", client_secret: "..."]]
```

Sessions are kept per principal whatever the credentials (see below), so
with `auth:` each principal's session obtains a token of its own.

With `credentials/1`, each principal acts as itself upstream. The
callback gets the request's `Sake.Context` (the principal is in
`ctx.scope`, the token in `ctx.token`) and returns `{:bearer, token}`,
`{:headers, headers}`, `:none`, or `{:error, message}` when the
principal has no credentials: the lists then leave the proxied
components out, and a call gets `message`. It may be called several
times per request, so read the token from wherever your app keeps it
quickly (or cache it).

Upstream sessions are kept per principal (the token's subject, else the
host's scope) and per credential, so one principal's session, token,
tasks and requests are never another's, and a new token gets a new
session. A session the upstream refuses (a 401, a legacy session it has
forgotten) is opened again once, with `credentials/1` asked again; a
refusal after that is an error. Unused sessions are closed after
`idle_timeout:` (ten minutes).

A stdio upstream is one subprocess, owned by the proxy, for everyone.
Its credentials come from its environment (`credentials/1` does not
apply), and the proxy sends it one request at a time: a stdio server
cannot tell which call its questions and log messages belong to.

### What is forwarded

- **Lists** come from the principal's upstream session, kept for the
  upstream's `ttlMs` (or `list_ttl:`, one minute, from a legacy
  upstream that does not say). They are `cacheScope: "private"`, as they
  depend on who asks; an upstream that cannot be reached lists nothing,
  and the server's own components are listed as ever.
- **Calls, reads, prompts and completions** go to the upstream, and its
  results come back as the proxy's. A URI under a mounted proxy's
  prefix is read from the upstream even when it does not list it (a
  resource link in a proxied result, say); its resource links and
  embedded resources take the prefix when they name one of the
  upstream's resources, and nothing else does (an `https://` link stays
  as it is). An upstream's JSON-RPC errors reach the client; a failure
  to reach the upstream is logged, and the client learns only that the
  upstream is not available.
- **Progress and log messages** of a call reach the client, at the
  client's log level.
- **Elicitation, sampling and roots requests** reach the client,
  whatever the eras. A modern upstream's input-required result becomes
  the proxy's own, with a `requestState` that carries the upstream's,
  signed and bound to the principal; a legacy client is asked on its
  stream instead, and the answers go back upstream. A legacy upstream
  asks on its stream: a legacy client, or a task's, answers while it
  waits, and a modern client gets the question as an input-required
  result; on its retry the call runs again upstream, and the question,
  asked again, is answered from the retry. As with Sake's own tools on
  the modern protocol, such an upstream tool runs once per round, and
  must ask before it acts.
- **Tasks**: a modern client that takes tasks gets an upstream's task
  as one of the proxy's own (see `guides/tasks.md`): a task ID of the
  proxy's, owned by the principal, whose status, questions and result
  follow the upstream's. `tasks/update` answers go upstream, and
  cancelling the task (or its expiry) cancels the upstream's.
- **MCP Apps**: an upstream's apps pass through. A proxied tool's
  `ui://` link and the app's resource take the mount's prefix.
- **Notifications**: when every principal has the same upstream identity
  (no `credentials/1`, or a stdio upstream), the proxy follows the
  upstream's list changes, which it broadcasts as its own after
  forgetting the cached lists, and the updates of the resources a
  client subscribed to through it (a legacy `resources/subscribe` or a
  `subscriptions/listen` stream). Both reach the clients of every server
  that mounts the proxy, with URIs under its prefix.

### Limits

- A proxy with `credentials/1` does not follow its upstream's
  notifications: each principal's upstream may announce different
  things, and the proxy does not keep a stream per principal. Its lists
  are fetched again after their ttl, and its resources take no
  subscriptions.
- A resource followed upstream stays followed while the proxy runs
  (up to a thousand of them): the proxy cannot tell when the last client
  that subscribed to it has gone.
- A legacy upstream session declares elicitation, sampling and roots
  when it opens, for every client: a question the client cannot answer
  is answered for it (an elicitation is cancelled, roots are none).
- The server's capabilities do not ask the upstream: a proxy declares
  tools, resources, prompts and completions as its options allow.
- The upstream's instructions are not passed on; give the proxy its own.

### Testing a proxy

Start the proxy in the test with an upstream of your own, served by
Bandit (or over stdio), and test it through `Sake.Test` as any server:

```elixir
setup do
  {:ok, _} = start_supervised({Bandit, plug: MyApp.FakeGitHub.Router, port: 4100})
  start_supervised!({MyApp.MCP.GitHub, upstream: "http://localhost:4100/mcp"})
  :ok
end

test "proxies the issues" do
  client = connect(MyApp.MCP.GitHub, scope: user, scopes: ["github"])
  assert {:ok, %{text: "Opened #1"}} = call_tool(client, "open_issue", %{"title" => "x"})
end
```
