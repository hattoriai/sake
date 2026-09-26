# Protocol versions

## The eras

MCP's `2026-07-28` revision ("modern" throughout Sake's code and docs) is
stateless: every request carries its own protocol version and client
capabilities, there is no `initialize` handshake and no session. The
three revisions before it — `2025-11-25`, `2025-06-18`, `2025-03-26`
("legacy") — share a handshake-and-session model: an `initialize` request
negotiates a revision and gets a session ID back, and every later request
on that connection carries it.

Sake serves both eras on the *same endpoint path*: a `POST` whose body's
method is `initialize` always opens a legacy session, regardless of what
the `MCP-Protocol-Version` header says (the header describes the one
request's transport, not the session it is asking to start); every other
modern-tagged request is dispatched statelessly. `Sake.Client.connect/2`
mirrors this from the other side — it tries the modern handshake first and
falls back to legacy automatically (see `guides/client.md`).

## What Sake serves and speaks

| | Server | Client |
|---|---|---|
| 2026-07-28 (modern) | full | full |
| 2025-11-25 | full | full |
| 2025-06-18 | full | full |
| 2025-03-26 | full (batching included) | connects, no batching |
| 2024-11-05 | not supported | not supported |

An unrecognized `MCP-Protocol-Version` header gets a `-32022` JSON-RPC
error listing `Sake.Protocol.supported/0`, so a client can retry with a
revision it can actually negotiate against.

## Headers

The modern transport mirrors the JSON-RPC body's method, tool/resource
name and (encoded) arguments onto `Mcp-Method`, `Mcp-Name` and
`Mcp-Param-*` headers (`Sake.Plug.Headers`), validated against the body on
every request — a proxy or gateway can route or log on headers alone
without parsing JSON. `Accept` must list both `application/json` and
`text/event-stream`; `MCP-Protocol-Version` selects the era as described
above; `Mcp-Session-Id` carries a legacy session (see
`guides/authorization.md` for how it also carries the current log level,
re-minted with no server-side session state).

## What is not supported

- **2024-11-05** — the revision before the current three-legacy-revision
  window; Sake does not negotiate it at all.
- **Resumability** — reconnecting a dropped SSE stream with
  `Last-Event-ID` and a server-issued `retry` interval. Neither `Sake.Plug`
  nor `Sake.Client` implements this; a dropped stream is simply gone.
- **Tasks** — the long-running, poll-or-push task primitive some 2026-era
  drafts describe is not implemented.
- **Apps** — UI-surface extensions layered on top of MCP are out of scope
  for this package entirely.
- **Sampling** — a server asking the *client's* model to complete a
  prompt (`sampling/createMessage`). `Sake.Elicit` covers the
  server-asks-the-person direction; there is no equivalent for
  server-asks-the-client's-LLM yet.
- **Roots** — the client-declares-its-workspace-folders capability has no
  server- or client-side support.

## Conformance status

The official `@modelcontextprotocol/conformance` suite (see
`conformance/`) runs in CI against the development server (`mix dev`'s
`/open/mcp`, unauthenticated) and, for the client suite, against
`Sake.Client` driving `conformance/client.exs`. As of the version pinned
in `conformance/package.json`, its own newest recognized `--spec-version`
is `2025-11-25` — it does not yet have scenarios for `2026-07-28` — so the
server suite runs against `2025-06-18` and `2025-11-25`; both exercise the
same dual-era endpoint a modern client also reaches once it opens a
session.

`conformance/expected-failures.yaml` is the baseline of scenarios that
fail on purpose; CI only turns red on a *new* failure. Currently:

- **`tools-call-sampling`** (server) — no sampling support (above).
- **`sse-retry`** (client) — no resumability (above).
- **`elicitation-sep1034-client-defaults`** (client) — the driver answers
  every elicitation with the request schema's declared defaults (what this
  scenario checks for), but the round-trip itself closes with an RPC error
  before any tool call completes; not chased down within this package's
  first release.
- **Every `auth/*` client scenario** (14 of them) — `Sake.Client` has no
  OAuth support at all yet (see the README's status line and
  `guides/client.md`'s "401 challenge" section); this is 0.1's largest
  known gap.
