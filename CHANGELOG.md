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
- `Sake.Auth.Store.ETS` (development) and `Sake.Auth.Store.Ecto`
  (production) token/client/code/consent stores, plus a grants API for a
  settings page and `Sake.Auth.prune/1` for expired rows.
- `Sake.Client`: a functional client for both protocol eras, with era
  probing, elicitation via `on_input`, and a parsed `WWW-Authenticate`
  challenge on a 401.
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
- `Sake.Stdio` and `mix sake.stdio`: the same server over standard input
  and output, on both eras, with concurrent requests, cancellation,
  progress and log notifications, elicitation, subscriptions, and
  shutdown when standard input closes. `Sake.Client.connect/2` launches
  a stdio server with `{:stdio, command, args}`, probing the era as the
  stdio transport asks; `on_notification:` sees a call's notifications
  on either transport.
- A development server (`mix dev`) and an end-to-end test driving the
  whole OAuth-to-tool-call flow through it.
- The official MCP conformance suite wired into CI, with a baseline of
  known, documented gaps (sampling, SSE resumability, the client's
  standalone GET stream); every `auth/*` client scenario passes.
