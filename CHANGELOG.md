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
  challenge on a 401 (client-side OAuth itself is not yet implemented).
- A development server (`mix dev`) and an end-to-end test driving the
  whole OAuth-to-tool-call flow through it.
- The official MCP conformance suite (0.2.0-alpha.12) wired into CI: the
  server and client scenarios of 2025-06-18, 2025-11-25 and 2026-07-28,
  the authorization-server scenarios against the development server's own
  authorization server, and, as a separate step, the extension scenarios.
  Its baselines list the known, documented gaps (sampling and roots, SSE
  resumability, the client's standalone GET stream, client-side OAuth,
  the tasks extension).
