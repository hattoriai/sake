# Changelog

## 0.1.0 (unreleased)

First release.

- `Sake.Server`, `Sake.Tool`, `Sake.Resource`, `Sake.Prompt`: declare
  tools, resources (fixed and templated, with subscriptions and
  completion) and prompts with a small DSL, compiled to JSON Schema.
- `Sake.Plug`: one endpoint serving the modern (2026-07-28), stateless
  protocol and the three handshake-era revisions (2025-11-25, 2025-06-18,
  2025-03-26) side by side, with Server-Sent Events streaming, progress
  and log notifications, and Origin checking.
- `Sake.Elicit` and `Sake.Progress`: ask the person for input mid-call
  (form and URL modes) and report progress or log messages, on both
  protocol eras.
- `Sake.Sampling` and `Sake.Roots`: ask the client's model to complete a
  conversation (with sampling tools from 2025-11-25) and ask for the
  client's roots, on both eras, through the same path as elicitation;
  `Sake.Input.all/2` asks several things in one round-trip.
- Tasks (`io.modelcontextprotocol/tasks`): a tool declared with `task:`
  runs in the background for a modern client that takes tasks, with
  `tasks/get`, `tasks/update` and `tasks/cancel`, input and progress
  through the task, cooperative cancellation (`Sake.Tasks.cancelled?/1`),
  `notifications/tasks` on `subscriptions/listen`, principal binding, and
  telemetry. `Sake.Tasks.Store.ETS` (default) and `Sake.Tasks.Store.Ecto`
  with `Sake.Tasks.Migration` for several nodes. A tool's optional
  `prepare/2` runs in the request before `execute/2`.
- MCP Apps (`io.modelcontextprotocol/ui`): `Sake.UI` declares an app's
  HTML document as a `ui://` resource with its `_meta.ui` (CSP,
  permissions, domain, border), from `render/1` (a string, iodata, or
  with `phoenix_html` a HEEx component) or an EEx template that escapes
  its output, with bundled assets inlined at compile time (`inline/1`).
  A tool links its app with `ui:` and limits its audience with
  `visibility:`. A client that declared the extension gets the tools'
  `_meta.ui`, the app-only tools and the UI resources, on both eras; any
  other client gets plain tools. The development server's issue board is
  an example app. `Sake.Client` declares the extension with `ui: true`
  and reads a tool's UI.
- A component can return `{:error, {:missing_capability, capabilities}}`
  for a `-32021` error naming the client capabilities it needs.
- `Sake.Router`: Phoenix router macros for the well-known, OAuth API,
  authorize, and endpoint routes, including under a scope with a dynamic
  tenant segment.
- An OAuth 2.1 authorization server on the host application's own login:
  bearer token validation, `/.well-known` discovery, Client ID Metadata
  Document support, dynamic client registration (RFC 7591), the
  authorize/consent flow, the token endpoint (authorization code + PKCE,
  refresh token rotation with reuse detection and family revocation), and
  revocation (RFC 7009). Consent is remembered per person, client and
  resource; a subject module's optional `authorize_resource?/2` refuses a
  tenant the person does not belong to. Works under a generated Phoenix
  endpoint (its parsed body, its `protect_from_forgery`).
- The authorization extensions on the authorization server. The client
  credentials grant (`io.modelcontextprotocol/oauth-client-credentials`)
  for machine clients the host registers with
  `Sake.Auth.Clients.create/2` (a secret, or public keys for
  `private_key_jwt`), acting as the principal the subject module's
  `client_principal/1` names, with tokens that have no subject. The JWT
  bearer grant (RFC 7523) for `trusted_issuers:` (`Sake.Auth.TrustedIssuer`):
  an enterprise identity provider's ID-JAG
  (`io.modelcontextprotocol/enterprise-managed-authorization`), verified
  for its type, issuer, audience, client, resource, expiry and single use,
  or a workload identity token, mapped to an account by the subject
  module's `assertion_principal/2`. Neither grant issues a refresh token;
  key sets are fetched and cached, `jti`s are remembered against replay,
  and the metadata advertises only what is configured. Signed JWTs need
  the optional `jose` dependency.
- `Sake.Auth.Store.ETS` (development) and `Sake.Auth.Store.Ecto`
  (production) token/client/code/consent stores, plus a grants API for a
  settings page and `Sake.Auth.prune/1` for expired rows.
- `Sake.Client`: a functional client for both protocol eras, with era
  probing, elicitation via `on_input`, sampling and roots via `sampling:`
  and `roots:`, log messages at `log_level:` (and `set_log_level/2`),
  tool calls followed through tasks (and
  `call_tool_async/3`, `get_task/2`, `update_task/3`, `cancel_task/2`),
  MCP Apps via `ui: true`, and a parsed `WWW-Authenticate` challenge on a 401.
- `Sake.Client.Auth`: with `auth:`, the client runs the MCP authorization
  flow itself on a 401: protected resource metadata (RFC 9728, from the
  challenge or the well-known URIs) checked against the endpoint,
  authorization server metadata (RFC 8414 and OpenID Connect Discovery,
  issuer validated), pre-registered credentials bound to their issuer, a
  Client ID Metadata Document, or dynamic registration (RFC 7591, with
  `application_type`), the authorization code with PKCE S256, `state`,
  `resource` (RFC 8707) and `iss` validation (RFC 9207), token endpoint
  authentication (`client_secret_basic`, `client_secret_post`, `none`),
  refresh before expiry and on a 401, step-up on a 403
  `insufficient_scope` with a retry limit, and the 2025-03-26 fallbacks.
  The interactive step is pluggable (`Sake.Client.Auth.Browser` with a
  loopback listener, `Sake.Client.Auth.Headless`), and so is token
  persistence (`Sake.Client.Auth.Store`).
- `Sake.Client.Auth` runs the grants without a person too: `grant:
  :client_credentials` (`client_secret_basic`, `client_secret_post` or
  `private_key_jwt`), `grant: :jwt_bearer` (a workload's JWT) and `grant:
  :enterprise` (the RFC 8693 token exchange of an ID token for an ID-JAG
  at the identity provider, then the JWT bearer grant), renewing an
  expiring token by running the grant again.
- `Sake.Stdio` and `mix sake.stdio`: the same server over standard input
  and output, on both eras, with concurrent requests, cancellation,
  progress and log notifications, elicitation, sampling and roots,
  subscriptions, tasks, and shutdown when standard input closes.
  `Sake.Client.connect/2` launches a stdio server with
  `{:stdio, command, args}`, probing the era as the stdio transport asks;
  `on_notification:` sees a call's notifications on either transport.
- OpenTelemetry tracing, with the optional `opentelemetry_api`, after the
  semantic conventions for MCP: a `SERVER` span for every request a
  server serves (HTTP on both eras, stdio), the child of the trace
  context in the request's `_meta` and linked to the transport's, and
  current where the component runs, so a tool's own spans and the
  client's baggage follow; an `execute_tool` span for a task's run, the
  child of the `tools/call` that started it; and a `CLIENT` span for
  every request `Sake.Client` sends, which carries the trace context in
  `_meta`. Tool arguments and results are recorded only with
  `config :sake, :opentelemetry, record_content: true`. The telemetry
  span `[:sake, :client, :request]`, for the client's operation
  durations. `guides/observability.md` lists the events and spans, and
  how to move from protocol logging to `Logger` and OpenTelemetry.
- `Sake.Test`: an in-memory client for a server's tests, on both eras.
  `Sake.Test.connect/2` gives a `Sake.Client` whose transport is the
  server itself: every request crosses as JSON into the real dispatchers
  with a real `Sake.Context`, and the calls are `Sake.Client`'s without
  the session. `scope:` sets the principal and `scopes:` a simulated
  token (a person's, or with `subject: nil` a machine client's) that the
  real scope checks gate; `on_input:`, `sampling:` and `roots:` answer
  the server, with shorter forms for tests; `assert_asked/2`,
  `assert_notification/2`, and `listen/2` with `assert_list_changed/1`
  and `assert_resource_updated/1` assert on what the server asked, sent
  and broadcast, per test, so tests can be `async: true`; tasks run in
  the background and are followed without sleeping through their poll
  interval (`await_task/3`); an exception in a component fails the test
  as it was raised. With `plug:`, the requests go over HTTP through the
  host's endpoint or router instead, with a real bearer token from
  `Sake.Test.access_token/1`. `Sake.Test.start/0` starts what Sake needs
  when the application does not. See `guides/testing.md`.
- `Sake.Middleware`: host code around a server's calls, declared on the
  server with `middleware event, plugs` (Plug-style modules with
  `init/1` and `call/2`, after Lotus's middleware). Events
  `:before_request` (every method), `:after_list` (the four lists),
  `:before_call`/`:after_call` (tools, a task's when it ends),
  `:before_read`/`:after_read` and `:before_get`/`:after_get`, with
  documented payloads; a `before_` plug may rewrite the arguments or
  parameters and an `after_` plug the result, and `:assigns` carries a
  decision to the later plugs and to the component (`ctx.assigns`). An
  `:after_list` plug that hides a component hides it from calls, reads,
  prompts, completions and subscriptions too, and makes lists
  `cacheScope: "private"`. A halt's reason maps to a small vocabulary
  (`:not_found`, `:forbidden`, `{:forbidden, scopes}` with its 403 and
  challenge, `{:error, message}`, `{:tool_error, message}`); any other
  reason is refused without saying why, and a plug that raises halts as
  a logged `-32603`. Both eras, every transport. Halts emit
  `[:sake, :middleware, :halt]` and mark the request's span. The
  development server logs its tool calls with one. See
  `guides/middleware.md`.
- Composing servers: `mount MyApp.MCP.Billing, prefix: "billing", scope:
  "billing"` makes another `Sake.Server`'s tools, resources and prompts
  the server's own, at any depth. Names take the prefix and an underscore
  (`billing_create_invoice`), URIs take it after the scheme
  (`invoice://billing/{id}`, `ui://billing/board`, with the linking
  tool's `_meta.ui` renamed too); names are checked for duplicates
  across all mounted servers at compile time. Instructions, scopes,
  extensions and capabilities merge; a mounted server's `ttl` bounds its
  components. Its middleware still runs around its components, inside
  the parent's (outermost first before a call, innermost first after
  it), and sees them by the names it gave them; its components see
  their own server in `ctx.server`, and its broadcasts reach the
  parent's clients with renamed URIs. See `guides/composing.md`.
- `Sake.Client.request/4` returns a result as the server sent it (an
  input-required result, a task), and `Sake.Client.listen/3` follows a
  server's list changes and resource updates on both eras. An answering
  function may throw to abandon a legacy call; a stdio session's
  requests go out under ids of the transport's own. A legacy GET stream
  sends a comment as soon as it opens.
- A development server (`mix dev`) and an end-to-end test driving the
  whole OAuth-to-tool-call flow through it.
- The official MCP conformance suite (0.2.0-alpha.12) wired into CI: the
  server and client scenarios of 2025-06-18, 2025-11-25 and 2026-07-28,
  the authorization-server scenarios against the development server's own
  authorization server, and, as a separate step, the extension scenarios.
  Its baselines list the known, documented gaps (SSE resumability, the
  client's standalone GET stream); every `auth/*` client scenario, every
  tasks extension scenario and every client auth extension scenario but
  DPoP's passes.
