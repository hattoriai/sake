# Sake

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

See `guides/quickstart.md` for turning on authorization in five steps, or
`mix dev` in this repository for a complete, running example.

## Features by era

| | 2026-07-28 (modern) | 2025-11-25 / 2025-06-18 | 2025-03-26 |
|---|---|---|---|
| Tools, resources, prompts | yes | yes | yes |
| Progress, logging | yes | yes | yes |
| Elicitation (form, url) | yes | yes (url from 2025-11-25) | form only |
| Subscriptions | `subscriptions/listen` stream | `resources/subscribe` | `resources/subscribe` |
| Batched requests | — (stateless, one at a time) | — | yes |
| `Sake.Client` | yes | yes | connects, no batching |

## The authorization flow, briefly

A client hits your endpoint, gets a 401, and discovers your app's
authorize and token URLs from well-known metadata. Your existing login
runs if the person is not signed in; a consent page shows what the client
is asking for; approving issues an authorization code, which the client
exchanges for an access and refresh token pair. Every later MCP request
carries the access token as a bearer credential, scoped to that one
endpoint's resource URL. See `guides/authorization.md`.

## Guides

- [Quickstart](guides/quickstart.md)
- [Tools](guides/tools.md)
- [Resources and prompts](guides/resources_and_prompts.md)
- [Authorization](guides/authorization.md)
- [Multi-tenant endpoints](guides/tenants.md)
- [The client](guides/client.md)
- [Protocol versions](guides/protocol_versions.md)
- [Security](guides/security.md)

## Status

0.1: the server (both eras, one endpoint), the authorization server
(bearer, CIMD, dynamic registration, consent, token rotation), and the
client. Next: client-side OAuth, a stdio transport, the device
authorization grant, and tasks.

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
