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

Sake needs Elixir 1.18 or later (for the built-in `JSON` module) on
OTP 27 or later; CI runs Elixir 1.18 (OTP 27), 1.19 (OTP 28) and 1.20
(OTP 29). Phoenix, Ecto, Phoenix.PubSub, `jose`, `phoenix_html` and
`opentelemetry_api` are optional: add the ones whose features you use.

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
| Client credentials, enterprise-managed authorization from an OpenID Connect or SAML sign-on (`Sake.Auth`, `Sake.Client`) | yes | yes | yes |
| DPoP, tokens bound to the client's key, offered or required (`Sake.Auth`, `Sake.Auth.External`, `Sake.Client`) | yes | yes | yes |
| Your own authorization server (`Sake.Auth.External`: JWT, introspection or a callback) | yes | yes | yes |
| The device authorization grant, for CLIs and devices without a browser (`Sake.Auth`, `Sake.Client`) | yes | yes | yes |
| Pushed authorization requests (`Sake.Auth`, `Sake.Client`) | yes | yes | yes |
| Step-up on how the person signed in: MFA, a recent sign-in (`Sake.Auth`, `Sake.Auth.External`, `Sake.Client`) | yes | yes | yes |
| OpenID Connect: ID tokens, userinfo, signing keys (`Sake.Auth`, `Sake.Client`) | yes | yes | yes |
| OpenTelemetry tracing, client to server to tool (trace context in `_meta`) | yes | yes | yes |
| `Sake.Test`, an in-memory client for a server's tests | yes | yes | yes |
| Middleware around calls (`Sake.Middleware`: audit, rate limits, plans, rewriting, redaction) | yes | yes | yes |
| Composing servers (`mount`, with prefixes) | yes | yes | yes |
| Proxying another server (`Sake.Proxy`, HTTP or stdio upstream of either era) | yes | yes | yes |
| Several nodes (shared Ecto stores, `pubsub:` for streams, a warning for node-local state) | yes | yes (with `pubsub:` or session affinity) | yes (with `pubsub:` or session affinity) |
| Your JSON library for your data (`JSON` or `Jason`) | yes | yes | yes |

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

An app that already runs OAuth, inside it (ExOauth2Provider, Boruta) or
at an identity provider (Keycloak, Auth0, Okta, Entra ID), keeps it:
Sake then only checks that server's tokens, as JWTs, by introspection or
with your own callback, and enforces the scopes (see
`guides/external_auth.md`).

Without a person at a browser, both sides also speak the official
authorization extensions: the client credentials grant for a service
acting as itself (with a secret, or a key and `private_key_jwt`), and
the JWT bearer grant for an enterprise identity provider's ID-JAG
(enterprise-managed authorization, from an OpenID Connect or a SAML
sign-on) or a workload's platform JWT, and
declare the extensions in their MCP capabilities. Signed
JWTs, and DPoP, need the optional `jose` dependency:

```elixir
{:jose, "~> 1.11"}
```

Client credentials with a secret (and the client's `client_secret_jwt`)
work without it.

Sake's own authorization server also offers, each when the host turns
it on: the device authorization grant (`device:`), for a CLI or a
device with no browser, where the person approves on any other device;
pushed authorization requests (`par:`), so the browser carries only a
`request_uri`; and OpenID Connect (`openid:`, with `signing_keys:`),
an ID token and a userinfo endpoint that say who signed in. A tool,
resource, prompt or server can ask how the person signed in
(`authentication: [acr: ["mfa"], max_age: 300]`, RFC 9470), and the
client steps up to meet it. `Sake.Client` speaks all of them. See
`guides/authorization.md` and `guides/client.md`.

## Guides

- [Quickstart](guides/quickstart.md)
- [Tools](guides/tools.md)
- [Tasks](guides/tasks.md)
- [MCP Apps](guides/apps.md)
- [Resources and prompts](guides/resources_and_prompts.md)
- [Authorization](guides/authorization.md)
- [Bring your own authorization server](guides/external_auth.md)
- [Multi-tenant endpoints](guides/tenants.md)
- [Middleware](guides/middleware.md)
- [Composing and proxying servers](guides/composing.md)
- [Shipping a server in a library](guides/libraries.md)
- [The client](guides/client.md)
- [Stdio](guides/stdio.md)
- [Observability](guides/observability.md)
- [Testing](guides/testing.md)
- [Protocol versions](guides/protocol_versions.md)
- [Security](guides/security.md)
- [Running on several nodes](guides/clustering.md)

## Conformance

The official MCP conformance suite (`@modelcontextprotocol/conformance`
0.2.0-alpha.12) runs in CI: the server and client scenarios of
2025-06-18, 2025-11-25 and 2026-07-28, the authorization-server
scenarios, and the extension scenarios (tasks, skills, and the client
auth extensions, DPoP included). Every extension scenario passes. Four
core scenarios are expected to fail, each for a documented reason (see
`guides/protocol_versions.md`): on the server, `server-sse-polling` (no
SSE resumability) and `input-required-result-ignore-extra-params`
(answers sent without the signed request state are asked for again); on
the client, `sse-retry` (no SSE resumability) and
`elicitation-sep1034-client-defaults` (the client answers no server
request sent on the standalone GET stream).

## Status

0.4: the server (both eras, one endpoint, and stdio; with elicitation,
sampling, roots, the tasks extension and MCP Apps), the authorization server
(bearer and DPoP-bound tokens, CIMD, dynamic registration, consent, token
rotation, machine clients, trusted identity providers and workloads, and
the scopes each person may hold; the device grant, pushed requests,
step-up on how the person signed in, and OpenID Connect), or
the host's own authorization server instead (JWT access tokens,
introspection, or a callback, with scopes, step-up and DPoP), and
the client (HTTP and stdio), which runs the MCP authorization flow itself
(discovery, CIMD or dynamic registration, PKCE, pushed requests, refresh,
step-up on scopes and on how the person signed in, an ID token, DPoP
with its nonces, or a grant without a person: client credentials, a JWT
bearer grant, enterprise-managed authorization with an ID token or a
SAML assertion; `client_secret_jwt` too, or the device grant for a person
on another device) and follows tasks; OpenTelemetry traces run from the
client's call through the server into the tool; `Sake.Test`, which
tests a server through an in-memory client; middleware, the host's
own code around every call; composing, one server mounted inside
another under a prefix, whole or in part, including a server a library
ships; and proxying, another MCP server's tools,
resources and prompts behind your own login, per-user credentials and
middleware, with input requests, tasks and notifications forwarded
across eras.

## Security

Report a vulnerability privately, as `SECURITY.md` says; please do not
open a public issue for one.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md): when a change needs an issue
first, and what a pull request needs.

## License

Sake is released under the MIT License. See `LICENSE`.
