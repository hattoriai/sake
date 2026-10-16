# Security

## Origin

`Sake.Plug`'s `origins:` option checks the `Origin` header of every
request that sends one. Only a browser sends an `Origin` header at all —
Claude Code, claude.ai's connectors, a CLI, a server-to-server
integration, none of them do — so a request with no `Origin` header is
always allowed, regardless of `origins:`; this check only ever matters for
a browser-based client, and only once one shows up.

A request that *does* carry an `Origin` header must be allowed on
purpose: the default (`origins:` omitted, i.e. `nil`) refuses it, full
stop. There is deliberately no implicit "the endpoint's own origin"
default computed from the request's own `Host` header — an earlier
version of this check did exactly that, and since `Host` is exactly what
an attacker performing DNS rebinding controls, an attacker whose `Origin`
header simply matched whatever `Host` they sent defeated it trivially, on
every endpoint. `origins: ["https://app.example.com", ...]` allows a
request whose (lower-cased) `Origin` is in the list; `origins: :any`
allows any `Origin` at all — reach for a list rather than `:any` unless
the endpoint is genuinely meant to be called from arbitrary browser
pages. A browser client of your own MCP server needs its origin added to
the list; nothing else does.

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

## Signed JWTs: client assertions and JWT grants

`private_key_jwt` client authentication and the JWT bearer grant (see
`guides/authorization.md`) trust a signature, so Sake is strict about
which ones it checks. Only RS256, PS256, ES256 and ES384 are accepted:
`none`, the HMAC algorithms (an HMAC "signed" with a public key is the
classic algorithm-confusion attack) and anything else are refused before
a key is looked at, and so is a token with a `crit` header. A key is
tried only with an algorithm of its own type, and only when its `kid`,
`use` and `alg` (when the JWK names them) fit; RSA keys under 2048 bits
and JWKs carrying private material are never used. The keys come only
from the client's registration or the trusted issuer's configuration
and metadata, never from the token's own header (DPoP proofs, below,
are the one exception, and why it is safe there is the point of that
section).

Every claim that binds the JWT is checked: `exp`, `nbf` and `iat` with
30 seconds of leeway, `iss` exactly, `aud` (this authorization server's
issuer or token endpoint URL), and for an ID-JAG its `typ`, its
`client_id` (the authenticated client) and its `resource`. A client
assertion must name the client as both `iss` and `sub`, and may not
claim to live longer than an hour.

Assertions and ID-JAGs are single use: their `jti` is remembered, per
issuer, until they expire. The memory is an ETS table on each node, so
in a cluster a JWT replayed to *another* node within its lifetime is not
caught; identity providers issue ID-JAGs for minutes, and Sake's client
signs its assertions for one, which keeps that window short. Key sets
fetched from a `jwks_uri` go through the same guarded download as a
Client ID Metadata Document (HTTPS, no redirects, 64 KB, five seconds),
but without the public-address check: those URLs come from your own
configuration and registrations, not from a stranger's request.

Neither the token endpoint's errors nor Sake's logs ever contain an
assertion, an ID token or a secret; an `error_description` names the
check that failed and nothing else. Tokens from these grants carry no
refresh token, so a machine client's or an identity provider's say ends
within one access token lifetime of being withdrawn.

## DPoP proofs

A DPoP proof (see `guides/authorization.md`) is the one JWT Sake verifies
with a key from its own header: the proof's job is to show possession of
*that* key. On its own, a valid signature then proves nothing about who
sent it; what makes it count is the RFC 7638 thumbprint of the key,
which the token endpoint binds the token to and the MCP endpoint compares
with the token's binding, in constant time. The header's key must be a
public one (a JWK with private material is refused), of a supported type
and strength; the algorithms are the same four as above, under the same
rules, and `typ` must be `dpop+jwt`.

Each proof is tied to its request: the method (`htm`) and the URL
(`htu`, compared without query or fragment, against the URL the request
reached or the endpoint's canonical resource, so a TLS-terminating proxy
in front does not break it), to the access token (`ath`, its SHA-256
hash) at the MCP endpoint, and to a time: no more than 30 seconds in the
future, nor more than five minutes (and 30 seconds) in the past. A proof
over 8 KB is refused before it is decoded, and a request with several
proofs is refused outright.

Proofs are single use: their `jti` is remembered per key for as long as
the proof would be accepted. Like the assertions', that memory is per
node; a server nonce (`dpop: [nonce: true]`) closes the gap a cluster
leaves, since a nonce is a MAC under the Sake secret that every node
checks the same way, valid for five to ten minutes, and so is the proof
that carries it. A proof refused only for its nonce is not recorded,
so the client's retry goes through.

A DPoP-bound token sent as a bearer token is refused, and so is an
unbound one sent with the `DPoP` scheme: the token's binding, not the
client, decides how it travels. A public client's refresh token is bound
to the key as well, so a stolen refresh token is as useless as a stolen
access token; trying one without the key still spends it, so the
legitimate client's next refresh shows the reuse and revokes the family.

The client keeps a token's private key next to the token, in the
session and in its token store (as PEM). A proxy's `credentials/1`
returns a bearer token or headers: a DPoP-bound token cannot be passed
through it, only obtained by the proxy's own `auth:`.

DPoP is opt-in for a client by default: a bearer token still works for a
client that asked for one. `dpop: [required: true]` closes that door for
the whole server (the MCP endpoint refuses `Bearer` outright, so a
leaked token of any kind is useless without its key), and a client
registered with `dpop_bound_access_tokens` closes it for itself, so that
no one holding its credentials can obtain an unbound token in its name.

## The CIMD fetch guard, and what it does not cover

`Sake.Auth.CIMD.fetch/2` resolves the client-supplied HTTPS host's
addresses and refuses to proceed unless every one of them is a public
unicast address (no loopback, link-local, RFC 1918, carrier-grade NAT,
multicast, reserved or benchmarking range, and no IPv6 address that
embeds or translates to an IPv4 one: IPv4-mapped, IPv4-compatible,
NAT64 `64:ff9b::/96`, 6to4 `2002::/16`) — this stops a client from
pointing your server's outbound fetch at its own internal network. A
`client_id` URL with credentials in it is refused, the whole download
runs under one 5-second deadline (a server that trickles bytes cannot
hold a request open), a document may list at most 10 redirect URIs, and
the document cache holds at most 1000 entries. It does **not** pin the actual HTTP connection to the address it
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
minutes. `inputResponses` sent without a `requestState` are ignored, even
if they would otherwise look like a plausible answer: the handler starts
over and asks its question again, so there is no unsigned path back into a
handler that is already mid-flow.

## Tasks

A task ID carries 144 random bits, and every task is bound to the
principal that created it — the token's subject, otherwise a SHA-256
digest of the host's scope. `tasks/get`, `tasks/update`, `tasks/cancel`
and a `subscriptions/listen` asking for `taskIds` treat another
principal's task exactly like one that does not exist. On an endpoint
with neither authorization nor a scope, the task ID is the only
credential, so keep it as secret as the result it unlocks. A
`tasks/update` answer only counts for a question the task is waiting
on; anything else is ignored. See `guides/tasks.md`.

## Proxies

A `Sake.Proxy` stands between your clients and another server, so it
keeps them apart there too:

- **Upstream sessions per principal.** A proxy keeps one upstream
  session per principal and per credential (a digest of what
  `credentials/1` returned, never the credential itself as a key): one
  person's upstream session, token, tasks or requests are never used for
  another's. Only a stdio upstream is shared, since it is one process,
  and the proxy sends it one request at a time, so that its questions
  and log messages reach the caller they belong to.
- **The upstream's request state, wrapped.** An upstream's
  `requestState` reaches the client only inside the proxy's own, signed
  and bound as above; a client cannot send its own in its
  `inputResponses` (keys under Sake's prefix are dropped), and another
  principal's is refused.
- **The upstream's tasks, re-issued.** A client gets a task of the
  proxy's, owned by its principal, never the upstream's task ID.
- **Untrusted upstreams.** What an upstream lists is validated: an entry
  of the wrong shape is left out, a tool's name must be one Sake
  accepts, no name becomes an atom, and an upstream component never
  shadows a local one of the same name. Its results and errors reach the
  client as an upstream's, and a failure to reach it is logged rather
  than described to the client.
- **Your scopes on their tools.** `scope:`, `scopes:` and middleware gate
  proxied components with your authorization server, and a component a
  plug hides is hidden from calls as well as lists.

## Loopback redirects

Sake accepts `https://` redirect URIs
unconditionally, and `http://` ones only on `127.0.0.1`, `[::1]`,
`localhost` or `::1` — RFC 8252's rule for native/CLI clients that cannot
reasonably terminate TLS on a local port. A loopback redirect's *port* is
allowed to differ from what was registered (the OS assigns an ephemeral
port to the client's local listener each run); everything else about the
URI must match exactly.

## The consent form

The consent form is protected in two layers:

- **The signed request blob.** The form's hidden `request` field is
  signed with your `secret_key_base`, bound to the signed-in person's
  subject ID, and expires after ten minutes. A form posted for anyone
  else, or later, is refused.
- **CSRF protection, when your pipeline has it.** When the authorize
  routes run behind `Plug.CSRFProtection` (`protect_from_forgery` in a
  Phoenix `:browser` pipeline), the consent form carries the real CSRF
  token and your pipeline checks it. A Plug-only host without CSRF
  middleware gets an empty `_csrf_token` field and relies on the signed
  blob alone — which is bound to the signed-in subject and expires in ten
  minutes.

The consent and error pages are sent with `x-frame-options: DENY` and
`content-security-policy: frame-ancestors 'none'`, so no other site can
frame them and trick a person into clicking "Allow" (clickjacking).

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
