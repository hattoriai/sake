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

Over stdio (`guides/stdio.md`) the same holds with the protocol version
in `_meta` in place of the header: `initialize` opens the process's one
legacy session, a request tagged with the modern revision is served
statelessly, and an untagged request belongs to the session. The
client's probe over stdio falls back to `initialize` on any error a
modern server would not send, or on no answer at all, as the stdio
transport asks.

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
  `Last-Event-ID` and a server-issued `retry` interval (removed from the
  2026-07-28 revision). Neither `Sake.Plug` nor `Sake.Client` implements
  this; a dropped stream is simply gone.
- **The client's standalone GET stream** — on a legacy session,
  `Sake.Client` does not open the `GET` stream a server may use for
  notifications and for requests unrelated to any call. A server request
  sent inside a call's own response stream (how a Sake server elicits) is
  answered; one sent only on the standalone stream never reaches the
  client.
- **The 2025-11-25 experimental tasks** — that revision's in-core task
  primitive (`tasks/result`, `tasks/list`, the `task` request parameter,
  `execution.taskSupport` on tools). Sake implements tasks as the
  2026-07-28 extension `io.modelcontextprotocol/tasks` instead (see
  `guides/tasks.md`), on the modern era only; a legacy session runs
  optional task tools synchronously and is refused required ones.

Sampling and roots are supported on every revision, deprecated as they are
in 2026-07-28 (SEP-2577); see `guides/tools.md`. So is logging
(`notifications/message`), which 2026-07-28 deprecates in favour of
standard error and OpenTelemetry.

The OpenTelemetry trace context keys of `_meta` (`traceparent`,
`tracestate`, `baggage`), which 2026-07-28 reserves, are read by the
server and written by `Sake.Client` on every revision: `_meta` is
allowed on every request of the legacy revisions too. See
`guides/observability.md`.

MCP Apps (the `io.modelcontextprotocol/ui` extension) work on every
revision: a host declares the extension in each request's capabilities on
2026-07-28 and in `initialize` on the legacy revisions, and the server
advertises it in `server/discover` and in its `initialize` result; see
`guides/apps.md`.

## Conformance status

The official `@modelcontextprotocol/conformance` suite (the version pinned
in `conformance/package.json`, 0.2.0-alpha.12) runs in CI through
`mix test.conformance` (`conformance/run.sh`) against the development
server:

- **Server scenarios**, for each of 2025-06-18, 2025-11-25 and 2026-07-28,
  against `/open/mcp` (`SakeDev.ConformanceServer`, unauthenticated). The
  suite speaks each revision's own wire: an `initialize` handshake and a
  session for the legacy two, stateless requests with per-request `_meta`
  for 2026-07-28 (`server-stateless`, `caching`, the header validation
  scenarios, `sep-2164-resource-not-found` and the `input-required-result-*`
  multi round-trip scenarios among them). Every scenario applicable to a
  revision runs, including the ones the suite still marks pending.
- **Client scenarios**, for the same three revisions, with `Sake.Client`
  driven by `conformance/client.exs` against the suite's reference servers.
- **Authorization-server scenarios** (`authorization-server-metadata-endpoint`,
  `authorization-code-grant`) against the development server's own
  authorization server. `conformance/authorization.sh` registers a client
  through dynamic client registration and plays the person in the browser:
  it signs in as the development account and approves the consent page.

`conformance/expected-failures.yaml` is the baseline of scenarios that fail
on purpose; CI turns red on a *new* failure and on a listed scenario that
now passes, and the suite counts a warning (an unmet SHOULD) as a failure.
Currently:

- **`server-sse-polling`** (server, 2025-11-25) — no resumability (above),
  so a stream carries no priming event and no `retry` field.
- **`input-required-result-ignore-extra-params`** (server, 2026-07-28) — the
  scenario sends answers with no `requestState`, to a question it never
  asked. Sake honours answers only alongside the signed state it issued
  for them (see `guides/security.md`), so it ignores them and asks again;
  the scenario expected the call to complete.
- **`sse-retry`** (client) — no resumability (above).
- **`elicitation-sep1034-client-defaults`** (client) — the fixture server
  sends its elicitation request outside the tool call's response stream,
  so it can only arrive on the standalone GET stream, which the client
  does not open (above).

Every `auth/*` client scenario of the core suite passes:
`conformance/client.exs` connects with `auth:`, with
`Sake.Client.Auth.Headless` standing in for the person (the suite's
authorization servers approve at once) and the pre-registered credentials
from `MCP_CONFORMANCE_CONTEXT` when a scenario provides them (see
`guides/client.md`'s "Authorization" section). The 2025-03-26
back-compatibility and draft auth scenarios, which CI does not run, pass
as well.

The extension scenarios (the tasks extension's `tasks-*`, the skills
extension's `sep-2640-*`, and the client auth extensions such as DPoP and
client credentials) belong to no revision. `mix test.conformance
extensions` runs them in a separate CI step against their own baseline,
`conformance/expected-failures-extensions.yaml`: every `tasks-*` scenario
passes (`tasks-status-notifications` is one the suite currently skips),
the skills scenarios pass as not applicable (Sake declares no skills
extension), and so do the client auth extensions' grants:
`auth/client-credentials-basic` and `auth/client-credentials-jwt` (the
client credentials grant with a secret and with `private_key_jwt`),
`auth/wif-jwt-bearer` (a workload's JWT as the grant) and
`auth/enterprise-managed-authorization` (the token exchange and the
ID-JAG), with `conformance/client.exs` passing each scenario's
credentials as `auth:` options. `auth/dpop` and `auth/dpop-nonce` fail:
the client does not bind its tokens to a key with DPoP (RFC 9449).
