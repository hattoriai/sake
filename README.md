# Sake

![Sake — MCP for Phoenix](https://raw.githubusercontent.com/hattoriai/sake/main/media/banner.png)

Sake (酒) is MCP for Elixir and Phoenix: a server that speaks the modern,
stateless 2026-07-28 protocol and the earlier handshake-and-session
protocol on one endpoint, an OAuth 2.1 authorization server that makes
your app's own login the identity provider, and a client for calling
other MCP servers.

## Quickstart

```elixir
def deps do
  [{:sake, "~> 0.1"}, {:bandit, "~> 1.5"}]
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
```

```elixir
# In your Phoenix router:
import Sake.Router
scope "/" do
  sake_endpoint "/mcp", server: MyApp.MCP
end
```

```
claude mcp add --transport http my-app https://myapp.example.com/mcp
```

Or, for a client on the same machine, over stdio (see `guides/stdio.md`):

```
claude mcp add --transport stdio my-app -- mix sake.stdio MyApp.MCP
```

See `guides/quickstart.md` for turning on authorization in five steps, or
`mix dev` in this repository for a complete, running example.

## Features by era

| | 2026-07-28 (modern) | 2025-11-25 / 2025-06-18 | 2025-03-26 |
|---|---|---|---|
| Tools, resources, prompts | yes | yes | yes |
| Progress, logging | yes (logging deprecated) | yes | yes |
| Elicitation (form, url) | yes | yes (url from 2025-11-25) | form only |
| Sampling, roots | yes (deprecated) | yes (sampling tools from 2025-11-25) | yes |
| Tasks (`io.modelcontextprotocol/tasks`) | yes | — (task tools run synchronously) | — |
| MCP Apps (`io.modelcontextprotocol/ui`) | yes | yes | yes |
| Subscriptions | `subscriptions/listen` stream | `resources/subscribe` | `resources/subscribe` |
| Batched requests | — (stateless, one at a time) | — | yes |
| Stdio transport | yes | yes | yes |
| `Sake.Client` (HTTP, stdio) | yes | yes | connects, no batching |
| `Sake.Client` authorization | yes | yes | yes (no resource metadata: the server's own) |
| Client credentials, enterprise-managed authorization (`Sake.Auth`, `Sake.Client`) | yes | yes | yes |
| DPoP, tokens bound to the client's key (`Sake.Auth`, `Sake.Client`) | yes | yes | yes |
| OpenTelemetry tracing, client to server to tool (trace context in `_meta`) | yes | yes | yes |
| `Sake.Test`, an in-memory client for a server's tests | yes | yes | yes |
| Middleware around calls (`Sake.Middleware`: audit, rate limits, plans, rewriting, redaction) | yes | yes | yes |
| Composing servers (`mount`, with prefixes) | yes | yes | yes |
| Proxying another server (`Sake.Proxy`, HTTP or stdio upstream of either era) | yes | yes | yes |

## The authorization flow, briefly

A client hits your endpoint, gets a 401, and discovers your app's
authorize and token URLs from well-known metadata. Your existing login
runs if the person is not signed in; a consent page shows what the client
is asking for; approving issues an authorization code, which the client
exchanges for an access and refresh token pair. Every later MCP request
carries the access token, scoped to that one endpoint's resource URL:
bound to a key the client holds when the client uses DPoP (RFC 9449),
with a fresh proof of that key on every request, or else as a bearer
credential. See `guides/authorization.md`; `Sake.Client`
runs the same flow from the client's side (`guides/client.md`).

Without a person at a browser, both sides also speak the official
authorization extensions: the client credentials grant for a service
acting as itself (with a secret, or a key and `private_key_jwt`), and
the JWT bearer grant for an enterprise identity provider's ID-JAG
(enterprise-managed authorization) or a workload's platform JWT. Signed
JWTs, and DPoP, need the optional `jose` dependency:

```elixir
{:jose, "~> 1.11"}
```

Client credentials with a secret work without it.

## Guides

- [Quickstart](guides/quickstart.md)
- [Tools](guides/tools.md)
- [Tasks](guides/tasks.md)
- [MCP Apps](guides/apps.md)
- [Resources and prompts](guides/resources_and_prompts.md)
- [Authorization](guides/authorization.md)
- [Multi-tenant endpoints](guides/tenants.md)
- [Middleware](guides/middleware.md)
- [Composing and proxying servers](guides/composing.md)
- [The client](guides/client.md)
- [Stdio](guides/stdio.md)
- [Observability](guides/observability.md)
- [Testing](guides/testing.md)
- [Protocol versions](guides/protocol_versions.md)
- [Security](guides/security.md)

## Status

0.1: the server (both eras, one endpoint, and stdio; with elicitation,
sampling, roots, the tasks extension and MCP Apps), the authorization server
(bearer and DPoP-bound tokens, CIMD, dynamic registration, consent, token
rotation, machine clients, trusted identity providers and workloads), and
the client (HTTP and stdio), which runs the MCP authorization flow itself
(discovery, CIMD or dynamic registration, PKCE, refresh, step-up, DPoP
with its nonces, or a grant without a person: client credentials, a JWT
bearer grant, enterprise-managed authorization) and follows tasks; OpenTelemetry traces run from the
client's call through the server into the tool; `Sake.Test`, which
tests a server through an in-memory client; middleware, the host's
own code around every call; composing, one server mounted inside
another under a prefix; and proxying, another MCP server's tools,
resources and prompts behind your own login, per-user credentials and
middleware, with input requests, tasks and notifications forwarded
across eras. Next: the device authorization grant.

## License

Sake is released under the MIT License. See `LICENSE`.
