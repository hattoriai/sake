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
| Progress, logging | yes | yes | yes |
| Elicitation (form, url) | yes | yes (url from 2025-11-25) | form only |
| Sampling, roots | yes (deprecated) | yes (sampling tools from 2025-11-25) | yes |
| Tasks (`io.modelcontextprotocol/tasks`) | yes | — (task tools run synchronously) | — |
| Subscriptions | `subscriptions/listen` stream | `resources/subscribe` | `resources/subscribe` |
| Batched requests | — (stateless, one at a time) | — | yes |
| Stdio transport | yes | yes | yes |
| `Sake.Client` (HTTP, stdio) | yes | yes | connects, no batching |
| `Sake.Client` authorization | yes | yes | yes (no resource metadata: the server's own) |

## The authorization flow, briefly

A client hits your endpoint, gets a 401, and discovers your app's
authorize and token URLs from well-known metadata. Your existing login
runs if the person is not signed in; a consent page shows what the client
is asking for; approving issues an authorization code, which the client
exchanges for an access and refresh token pair. Every later MCP request
carries the access token as a bearer credential, scoped to that one
endpoint's resource URL. See `guides/authorization.md`; `Sake.Client`
runs the same flow from the client's side (`guides/client.md`).

## Guides

- [Quickstart](guides/quickstart.md)
- [Tools](guides/tools.md)
- [Tasks](guides/tasks.md)
- [Resources and prompts](guides/resources_and_prompts.md)
- [Authorization](guides/authorization.md)
- [Multi-tenant endpoints](guides/tenants.md)
- [The client](guides/client.md)
- [Stdio](guides/stdio.md)
- [Protocol versions](guides/protocol_versions.md)
- [Security](guides/security.md)

## Status

0.1: the server (both eras, one endpoint, and stdio; with elicitation,
sampling, roots and the tasks extension), the authorization server
(bearer, CIMD, dynamic registration, consent, token rotation), and the
client (HTTP and stdio), which runs the MCP authorization flow itself
(discovery, CIMD or dynamic registration, PKCE, refresh, step-up) and
follows tasks. Next: the device authorization grant.

## License

Sake is released under the MIT License. See `LICENSE`.
