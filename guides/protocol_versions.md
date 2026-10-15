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
method is `initialize` opens a legacy session, regardless of what the
`MCP-Protocol-Version` header says (the header describes the one
request's transport, not the session it is asking to start), unless it
carries the modern per-request `_meta`: then it comes from a modern
client, and gets the modern "method not found" (`-32601`, HTTP 404) like
any other method the modern revision removed. Every other modern-tagged
request is dispatched statelessly, and a modern client never opens a
session. `server/discover` lists every revision the endpoint serves, the
legacy ones included, the same list an unsupported version error carries. `Sake.Client.connect/2` mirrors this from the other side
— it tries the modern `server/discover` first and falls back to the legacy
`initialize` when the server answers "method not found" (`-32601`),
"invalid params" (`-32602`) or with no JSON-RPC error at all (see
`guides/client.md`).

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
revision it can actually negotiate against. A modern request whose `_meta`
lacks the protocol version (or the client capabilities) is invalid
(`-32602`); one whose `_meta` names a different version than the header is
a header mismatch (`-32020`).

## Headers

The modern transport mirrors the JSON-RPC body's method, tool/resource
name and (encoded) arguments onto `Mcp-Method`, `Mcp-Name` and
`Mcp-Param-*` headers (`Sake.Plug.Headers`), validated against the body on
every request — a proxy or gateway can route or log on headers alone
without parsing JSON. Whitespace around a header value is not part of
it (RFC 9110), so `Mcp-Name:  add ` matches a body name of `add`; a value
that really starts or ends with a space travels Base64-encoded. `Accept`
must list both `application/json` and `text/event-stream`;
`MCP-Protocol-Version` selects the era as described above;
`Mcp-Session-Id` carries a legacy session. The session ID is a signed
token that also carries the log level `logging/setLevel` last set (the
server keeps no session state; see `Sake.Server.Session`): after
`logging/setLevel`, and when an ID gets old, the response carries a
re-minted ID for the same session, which the client uses from then on.
Because nothing is stored, a session cannot be ended early: a `DELETE`
gets `405 Method Not Allowed`, which the legacy revisions allow for a
server that does not support explicit termination, and the ID keeps
working until it expires.

## What is not supported

- **2024-11-05** — the revision before the current three-legacy-revision
  window; Sake does not negotiate it at all.
- **Resumability** — reconnecting a dropped SSE stream with
  `Last-Event-ID` and a server-issued `retry` interval. Neither `Sake.Plug`
  nor `Sake.Client` implements this; a dropped stream is simply gone.
- **The client's standalone GET stream** — on a legacy session,
  `Sake.Client` does not open the `GET` stream a server may use for
  notifications and for requests unrelated to any call. A server request
  sent inside a call's own response stream (how a Sake server elicits) is
  answered; one sent only on the standalone stream never reaches the
  client.
- **Tasks** — the long-running, poll-or-push task primitive some 2026-era
  drafts describe is not implemented.
- **Apps** — UI-surface extensions layered on top of MCP are out of scope
  for this package entirely.
- **Sampling** — a server asking the *client's* model to complete a
  prompt (`sampling/createMessage`), whether as a legacy server-to-client
  request or as an input request of a modern input-required result.
  `Sake.Elicit` covers the server-asks-the-person direction; there is no
  equivalent for server-asks-the-client's-LLM yet.
- **Roots** — the client-declares-its-workspace-folders capability
  (`roots/list`) has no server- or client-side support, in either era.

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
- **`elicitation-sep1034-client-defaults`** (client) — the fixture server
  sends its elicitation request outside the tool call's response stream,
  so it can only arrive on the standalone GET stream, which the client
  does not open (above).
- **Every `auth/*` client scenario** (14 of them) — `Sake.Client` has no
  OAuth flow of its own (see `guides/client.md`'s "401 challenge"
  section).
