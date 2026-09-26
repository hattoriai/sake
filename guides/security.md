# Security

## Origin

`Sake.Plug`'s `origins:` option checks the `Origin` header of every
request (browser-originated cross-site requests carry one; most other
clients do not, and a request with no `Origin` header at all is always
allowed — this check is CORS-shaped, not a general access control).
Default (`origins:` omitted): only the endpoint's own computed origin
(scheme, host, port from the request itself) is accepted. A list accepts
those values plus the endpoint's own origin. `origins: :any` disables the
check entirely.

**Open defect, read before setting `origins: :any` on an unauthenticated
endpoint reachable from a browser:** the default same-origin check
computes "the endpoint's own origin" from the *incoming request's own*
`Host` header — the same thing an attacker attempting DNS rebinding
controls — so an attacker whose `Origin` header simply matches whatever
`Host` they sent already defeats it, on every endpoint, not only ones
using `:any`. The official MCP conformance suite's `dns-rebinding-
protection` scenario catches exactly this on an unauthenticated,
plain-HTTP, localhost-bound endpoint (see `guides/protocol_versions.md`
for its status in the conformance baseline). A safe fix needs a
Host-validation check that does not simply widen what `origins:` already
controls, since the naive version of that check misfires on legitimate
same-host reverse-proxy setups — not yet done. Until it is: put `auth:
true` on any endpoint a browser can reach, or terminate it behind TLS with
a reverse proxy that validates `Host` itself.

## HTTPS

The authorization server's `issuer` must be an `https://` URL —
`Sake.Auth.Config.new/1` raises otherwise — because bearer tokens and
authorization codes are only as safe as the transport they travel over.
`allow_insecure: true` (below) is the explicit, development-only escape
hatch.

## PKCE

Every authorization code exchange requires a `code_challenge` (S256 only)
at the authorize step and the matching `code_verifier` at the token step;
Sake's PKCE check compares them with `Plug.Crypto.secure_compare/2`
(constant-time) and rejects a verifier outside the 43–128 byte range RFC
7636 requires. There is no `plain` method — S256 only.

## Hashed tokens, never stored raw

A SHA-256, hex-encoded hash is what actually lands in
a store row's `hash` column; the plain access and refresh tokens returned
to a client are never persisted anywhere. A compromised database dump
cannot be replayed as a bearer token or a refresh token — only a live
in-flight token (already in a client's or an attacker's hands some other
way) works at all.

## Family revocation

An authorization code and every access/refresh pair descended from it
share a `family_id`. Replaying a spent code, or a refresh token that was
already used once, revokes the *whole family* rather than denying just
that one request — a stolen, already-superseded credential cannot be used
to mint a fresh pair once the legitimate holder has moved past it. See
`guides/authorization.md`'s "Token lifetimes and rotation".

## The CIMD fetch guard, and what it does not cover

`Sake.Auth.CIMD.fetch/2` resolves the client-supplied HTTPS host's
addresses and refuses to proceed unless every one of them is a public
unicast address (no loopback, link-local, or RFC 1918 range) — this stops
a client from pointing your server's outbound fetch at its own internal
network. It does **not** pin the actual HTTP connection to the address it
just checked: the check-then-connect happens as two separate steps
(`:inet.getaddrs/2`, then `Req`'s own connection), and a hostile or
compromised DNS resolver that returns a public address to the check and a
private one to the actual connect (a classic TOCTOU/DNS-rebinding gap)
can still redirect the fetch. Mitigating this fully needs connecting to
the checked address directly rather than resolving the hostname a second
time — not implemented in 0.1. This is a real but narrow risk: it needs
control over DNS resolution for the specific client-supplied host, not
just the ability to register a client.

## `requestState`

The opaque `requestState` a multi-round-trip tool call carries between an
input-required response and its retry (the `requestState` field) is a
signed token binding the principal, the method, the component name, and a
digest of the original arguments — a retry cannot be replayed against a
different principal, a different tool, or with different arguments than
the ones that triggered the original elicitation, and expires after ten
minutes. `inputResponses` sent without a `requestState` are rejected
outright, even if they would otherwise look like a plausible answer: there
is no unsigned path back into a handler that is already mid-flow.

## Loopback redirects

Sake accepts `https://` redirect URIs
unconditionally, and `http://` ones only on `127.0.0.1`, `[::1]`,
`localhost` or `::1` — RFC 8252's rule for native/CLI clients that cannot
reasonably terminate TLS on a local port. A loopback redirect's *port* is
allowed to differ from what was registered (the OS assigns an ephemeral
port to the client's local listener each run); everything else about the
URI must match exactly.

## Rate limiting

Sake does not rate-limit anything itself — that is your reverse proxy's or
your Plug pipeline's job, and it belongs in front of the specific
endpoints that need it: `POST /oauth/register` (unauthenticated by
design, see `guides/authorization.md`), the token endpoint (bearer-adjacent
brute-force surface), and the authorize/consent endpoints (email- or
account-enumeration-adjacent, once behind your own login).

## `allow_insecure`

```elixir
auth: [..., allow_insecure: true]
```

Lets the issuer be an `http://` URL (for `mix dev` and tests) and widens
what `Sake.Auth.CIMD` will fetch from to include plain `http://` client-id
URLs. Never set this outside development — every guarantee above about
tokens travelling only over TLS depends on it being false.
