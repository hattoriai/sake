# Sake

[![Hex.pm](https://img.shields.io/hexpm/v/sake.svg)](https://hex.pm/packages/sake)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/sake)
[![CI](https://github.com/hattoriai/sake/actions/workflows/ci.yml/badge.svg)](https://github.com/hattoriai/sake/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

![Sake — MCP for Phoenix](https://raw.githubusercontent.com/hattoriai/sake/main/media/banner.png)

**Put your Phoenix app in front of Claude, ChatGPT and every other MCP
client, with your own users signing in.**

Sake (酒) is a Model Context Protocol server, client and OAuth 2.1
authorization server for Elixir. It does three things other MCP
libraries leave to you:

- **Your login is the identity provider.** Sake ships a complete OAuth
  2.1 authorization server: discovery, PKCE, dynamic registration,
  consent, token rotation. A person connects Claude to your app, signs
  in with the account they already have, and every tool call knows who
  they are. If you already run Keycloak, Auth0, Okta or Entra ID, Sake
  checks their tokens instead.
- **One endpoint serves every client.** The stateless 2026-07-28
  protocol and the older handshake-and-session revisions (2025-11-25,
  2025-06-18, 2025-03-26) share one path. Old clients and new ones both
  connect.
- **The client logs itself in.** `Sake.Client` runs the whole MCP
  authorization flow against any server: discovery, registration, PKCE,
  refresh, step-up and DPoP. Your code doesn't build URLs or store
  tokens.

The official MCP conformance suite runs in CI on every commit (see
[Conformance](#conformance)). MIT licensed.

## Quickstart

```elixir
def deps do
  [{:sake, "~> 0.4"}, {:bandit, "~> 1.5"}]
end
```

```elixir
defmodule MyApp.MCP.Echo do
  use Sake.Tool, name: "echo", description: "Returns the text it receives"
  arg :text, :string, required: true

  @impl true
  def execute(%{text: text}, _ctx), do: {:ok, text}
end

defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  tools [MyApp.MCP.Echo]
end
```

```elixir
# In your supervision tree:
{Sake, secret_key_base: MyAppWeb.Endpoint.config(:secret_key_base)}

# In your Phoenix router:
import Sake.Router
scope "/" do
  sake_endpoint "/mcp", server: MyApp.MCP
end
```

Then connect a client:

```bash
claude mcp add --transport http my-app https://myapp.example.com/mcp
```

Or, on the same machine, over stdio:

```bash
claude mcp add --transport stdio my-app -- mix sake.stdio MyApp.MCP
```

`mix dev` in this repository starts a complete example app with a login
form, the OAuth endpoints, and sample tools, resources and prompts.

## Require a signed-in user

Mark the scope a tool needs. Then turn on `auth:`, add the router
macros, and put your existing login pipeline in front of the authorize
page:

```elixir
defmodule MyApp.MCP.CloseIssue do
  use Sake.Tool, name: "close_issue", description: "Close an issue", scope: "issues:write"
  arg :id, :integer, required: true

  @impl true
  def execute(%{id: id}, ctx) do
    with {:ok, _issue} <- MyApp.Issues.close(ctx.scope, id), do: {:ok, "Closed ##{id}"}
  end
end
```

```elixir
{Sake,
 secret_key_base: MyAppWeb.Endpoint.config(:secret_key_base),
 auth: [
   subject: MyApp.MCP.Subject,   # reads the signed-in user from the conn
   issuer: "https://myapp.example.com",
   servers: [MyApp.MCP],
   store: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}
 ]}
```

```elixir
scope "/" do
  sake_well_known()
  sake_endpoint "/mcp", server: MyApp.MCP, auth: true
end

scope "/oauth" do
  pipe_through :api
  sake_oauth_api()
end

scope "/oauth" do
  pipe_through [:browser, :require_authenticated_user]
  sake_oauth_authorize()
end
```

Now a client that connects gets a 401, finds your authorize URL, and
opens your login page. The person approves on a consent page and the
client gets tokens scoped to this endpoint. Each tool sees the user in
`ctx.scope`. A client without `issues:write` never sees `close_issue`.
Calling it anyway asks the client to step up.

The [quickstart guide](guides/quickstart.md) covers all five steps,
including the subject module and the migration.

## Test it like a controller

`Sake.Test` connects to your server in memory, so a test reads like
real client code. Argument validation, scope checks, errors, telemetry
and traces all run for real. Only HTTP is skipped.

```elixir
import Sake.Test

test "a reader cannot close issues" do
  client = connect(MyApp.MCP, scope: user_fixture(), scopes: ["issues:read"])

  assert {:ok, tools} = list_tools(client)
  refute "close_issue" in Enum.map(tools, & &1.name)

  assert {:error, {:insufficient_scope, _}} = call_tool(client, "close_issue", %{"id" => 1})
end
```

## Call other MCP servers

```elixir
{:ok, session} = Sake.Client.connect("https://mcp.example.com/mcp")
{:ok, tools, session} = Sake.Client.list_tools(session)
{:ok, result, session} = Sake.Client.call_tool(session, "search", %{"query" => "x"})
```

When the server asks for authorization, the client runs the flow
itself: discovery, Client ID Metadata Documents or dynamic registration,
PKCE, pushed requests, refresh, and step-up. A service without a person
at a browser can use client credentials, a JWT bearer grant, or
enterprise-managed authorization from an OpenID Connect or SAML sign-on.
See the [client guide](guides/client.md).

## Proxy a third-party server behind your login

Put an upstream MCP server behind your own users, scopes and
middleware, with per-user credentials:

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

## What's included

**Protocol**
- Tools, resources, resource templates, prompts and completion
- Elicitation (form and URL), sampling, roots, progress, logging
- Tasks (`io.modelcontextprotocol/tasks`), MCP Apps (`io.modelcontextprotocol/ui`), Skills (`io.modelcontextprotocol/skills`)
- Subscriptions: `subscriptions/listen` on modern clients, `resources/subscribe` on older ones
- Streamable HTTP and stdio, with JSON-RPC batching on 2025-03-26

**Authorization server** (`Sake.Auth`)
- OAuth 2.1 with PKCE, dynamic registration, Client ID Metadata Documents, consent, refresh token rotation
- Bearer or DPoP-bound tokens (RFC 9449), offered or required
- Machine clients: client credentials with a secret, `client_secret_jwt` or `private_key_jwt`
- Enterprise-managed authorization (ID-JAG) and workload identity
- Device authorization grant for CLIs, pushed authorization requests, OpenID Connect (ID tokens, userinfo)
- Step-up on how the person signed in, such as MFA or a recent sign-in (RFC 9470)
- Per-person scope limits and multi-tenant endpoints

**Bring your own authorization server** (`Sake.Auth.External`)
- JWT validation, token introspection, or your own callback, with scopes, step-up and DPoP

**Building and running**
- `Sake.Middleware` around every call: audit, rate limits, plans, rewriting, redaction
- `mount` one server inside another under a prefix, including servers shipped in libraries
- `Sake.Proxy` for an HTTP or stdio upstream on either protocol era
- OpenTelemetry traces from the client's call through the server into the tool
- Several nodes, with shared Ecto stores and `pubsub:` for streams
- `JSON` or `Jason` for your data

The [protocol versions guide](guides/protocol_versions.md) shows which
features each revision supports.

## Conformance

CI runs the official MCP conformance suite
(`@modelcontextprotocol/conformance` 0.2.0-alpha.12) on every commit.
It covers the server and client scenarios of 2025-06-18, 2025-11-25 and
2026-07-28, the authorization-server scenarios, and the extension
scenarios (tasks, skills, and client auth extensions including DPoP).

Every extension and auth scenario passes. Four core scenarios are
expected to fail, and each has a documented reason in
[protocol versions](guides/protocol_versions.md):

| Scenario | Side | Why |
|---|---|---|
| `server-sse-polling` | server | No SSE resumability yet |
| `sse-retry` | client | No SSE resumability yet |
| `input-required-result-ignore-extra-params` | server | Answers without the signed request state are asked again |
| `elicitation-sep1034-client-defaults` | client | The client doesn't answer server requests on the standalone GET stream |

## Not there yet

- **SSE resumability.** A dropped stream isn't replayed from
  `Last-Event-ID`. The client has to retry the request.
- **No Redis store.** State lives in ETS or in your Ecto repo.
- **Pre-1.0.** The API can still change between minor versions. Each
  change is in the [changelog](CHANGELOG.md).

## Requirements

Elixir 1.18 or later on OTP 27 or later. CI runs Elixir 1.18 (OTP 27),
1.19 (OTP 28) and 1.20 (OTP 29). Phoenix, Ecto, Phoenix.PubSub, `jose`,
`phoenix_html` and `opentelemetry_api` are optional. Add the ones whose
features you use. Signed JWTs and DPoP need `{:jose, "~> 1.11"}`.

## Guides

- **Start:** [Quickstart](guides/quickstart.md) · [Tools](guides/tools.md) · [Resources and prompts](guides/resources_and_prompts.md) · [Testing](guides/testing.md)
- **Auth:** [Authorization](guides/authorization.md) · [Bring your own authorization server](guides/external_auth.md) · [Multi-tenant endpoints](guides/tenants.md) · [Security](guides/security.md)
- **Protocol:** [Tasks](guides/tasks.md) · [MCP Apps](guides/apps.md) · [Skills](guides/skills.md) · [Protocol versions](guides/protocol_versions.md) · [Stdio](guides/stdio.md)
- **Architecture:** [Middleware](guides/middleware.md) · [Composing and proxying](guides/composing.md) · [Shipping a server in a library](guides/libraries.md) · [The client](guides/client.md)
- **Operations:** [Observability](guides/observability.md) · [Running on several nodes](guides/clustering.md)

## Security

Report vulnerabilities privately, as [SECURITY.md](SECURITY.md)
describes. Please don't open a public issue for one.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) explains when a change needs an issue
first and what a pull request needs.

## License

MIT. See [LICENSE](LICENSE).
