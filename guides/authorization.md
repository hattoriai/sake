# Authorization

Sake's authorization server makes your Phoenix (or Plug) app itself the
OAuth 2.1 authorization server for its own MCP endpoint: your login, your
users, no third-party identity provider. See `guides/quickstart.md` for the
five-step setup; this guide is the flow end to end, and the pieces you can
replace or extend. An app that already has an authorization server keeps
it, and Sake only checks its tokens: see `guides/external_auth.md`.

## The flow, as a person sees it

1. A client (Claude Code, Claude Desktop, a custom agent) is pointed at
   your MCP endpoint. It gets a 401 with a `WWW-Authenticate` header
   naming the endpoint's metadata URL.
2. The client fetches `/.well-known/oauth-protected-resource/...` and then
   the authorization server's own `/.well-known/oauth-authorization-server`
   (served by `Sake.Auth.WellKnown`), learning the authorize/token URLs and
   the scopes your servers declare.
3. The client registers itself — dynamically (see DCR below), or by
   presenting a Client ID Metadata Document — and opens the authorize URL
   in a browser.
4. The person must be signed in. `Sake.Auth.Authorize` reads the
   principal through your `Sake.Auth.Subject` module; for a signed-out
   person it answers a 401 page ("Sign in first"). To send the person to
   your login page instead, put your own plug in front of the route — the
   generated `require_authenticated_user` plug in a Phoenix app does
   exactly that, and returns the person to the authorize URL after login.
   A subject module that defines `authorize_resource?/2` may refuse the
   endpoint the client asked for (see `guides/tenants.md`); the client
   then gets `access_denied`.
5. The consent page (`Sake.Auth.Consent.Default`, or your own) shows the
   client's name, the endpoint URL (the resource) and the scopes it asked
   for. Approving redirects back to
   the client with an authorization code.
6. The client exchanges the code (with its PKCE verifier) for an access
   token and a refresh token at `/oauth/token`.
7. The access token goes with every MCP request from then on — bound to
   a key the client holds, when the client uses DPoP (below), or as a
   bearer token — and the refresh token gets a new pair when the access
   token expires.

## The three client kinds

A `Sake.Auth.Client` comes from one of three places (`kind:` records
which):

- **Client ID Metadata Document (CIMD)** — the client's `client_id` is an
  HTTPS URL; `Sake.Auth.CIMD.fetch/2` downloads the JSON document there and
  builds a client from it, caching the result for its `max-age` (clamped
  to one minute–one day). No registration step at all.
- **Dynamically registered (DCR)** — `POST /oauth/register`
  (`Sake.Auth.DCR`, RFC 7591) creates a public client from a JSON body;
  put a rate limit in front of it, since it is unauthenticated by design.
- **Host-registered** — your own code calls `Sake.Auth.Clients.create/2`
  for a CLI or a partner integration you control; `confidential: true`
  returns a client secret once, for a client that can keep one. Machine
  clients and the clients that present JWT grants (below) are
  host-registered too.

## Machine clients (client credentials)

A service that calls your endpoint as itself — a nightly job, a CI
pipeline, another backend — has no person to send to a consent page. It
uses the client credentials grant (the
`io.modelcontextprotocol/oauth-client-credentials` extension): it
authenticates at `/oauth/token` and gets an access token for itself.

You register such a client yourself; dynamic registration never creates
one, since anyone may call it, and the extension asks for credentials
established out of band:

```elixir
# With a secret, returned once:
{:ok, client, secret} =
  Sake.Auth.Clients.create(config, %{
    name: "Nightly report",
    grant_types: ["client_credentials"],
    confidential: true,
    scopes: ["reports:read"]
  })

# Or with the client's public keys (private_key_jwt, RFC 7523 §2.2): the
# client signs a short-lived JWT for each token request, and no secret
# exists to leak.
{:ok, client, nil} =
  Sake.Auth.Clients.create(config, %{
    name: "Nightly report",
    grant_types: ["client_credentials"],
    jwks: %{"keys" => [public_jwk]},       # or jwks_uri: "https://..."
    scopes: ["reports:read"]
  })
```

A machine client needs no redirect URI. Keys need the optional `jose`
dependency (`{:jose, "~> 1.11"}`); a secret does not.

The grant is offered only when your subject module defines
`client_principal/1`, which names the principal the client acts as (or
returns `:error` to refuse it). It is called when the token is issued
and again on every request the token makes, as `fetch/1` is for a
person, so a client you cut off stops at once:

```elixir
@impl true
def client_principal(%Sake.Auth.Client{id: id}), do: MyApp.Integrations.fetch_service_account(id)
```

The token has no subject: `ctx.token.subject_id` is `nil` and
`ctx.token.client_id` names the client, so a tool can tell a machine
from a person. Its scopes are the ones asked for (all the servers'
scopes by default), narrowed to the client's `scopes:`; a request for
nothing the client may have gets `invalid_scope`. The `resource`
parameter names the endpoint, as for any token. There is no refresh
token (RFC 6749 §4.4.3): the client asks again with its credentials. A
public client is refused (`unauthorized_client`), whatever it lists in
its `grant_types`.

## Trusted issuers: enterprise identity providers and workloads

The JWT bearer grant (`urn:ietf:params:oauth:grant-type:jwt-bearer`,
RFC 7523) issues a token for a JWT that an issuer you trust signed:

- **Enterprise-managed authorization** (the
  `io.modelcontextprotocol/enterprise-managed-authorization` extension).
  The company's identity provider (Okta, Entra ID, ...) decides which of
  its people may use which client with your server. The client exchanges
  the person's single sign-on ID token at the identity provider for an
  Identity Assertion JWT Authorization Grant (ID-JAG), and presents it
  here; the person never sees a consent page. A client whose single
  sign-on is SAML first trades the SAML assertion for a refresh token
  at the identity provider, then that for the ID-JAG; nothing changes
  here, where an ID-JAG arrives either way.
- **Workload identity.** A CI system, a cloud or Kubernetes gives each
  workload a signed JWT naming it; the workload presents that JWT and
  needs no secret of its own.

```elixir
{Sake,
 auth: [
   ...,
   trusted_issuers: [
     [issuer: "https://acme.okta.com", clients: [agent_client_id]],
     [
       issuer: "https://token.actions.githubusercontent.com",
       profile: :workload,
       audiences: ["https://mcp.example.com"],
       scopes: ["issues:read"],
       clients: [ci_client_id]
     ]
   ]
 ]}
```

See `Sake.Auth.TrustedIssuer` for every option. The issuer's keys come
from `jwks:` or `jwks_uri:`, or else from the `jwks_uri` of its OpenID
Connect (or RFC 8414) metadata; they are cached, and fetched again for a
key ID the cache does not know, at most once a minute. A client presents
an issuer's grants only when the issuer's `clients:` names it and its
own `grant_types` include the JWT bearer grant; it authenticates as it
would for any grant (a public client by its `client_id`).

An ID-JAG (`profile: :id_jag`, the default) is accepted when it is typed
`oauth-id-jag+jwt`, signed by the issuer, issued for this authorization
server (`aud` is your issuer or token endpoint URL, unless `audiences:`
says otherwise), unexpired, issued to the very client presenting it
(`client_id`), for one of your endpoints (`resource`, when present), and
not seen before (`jti`). Its `scope` limits the token's. A workload
token (`profile: :workload`) needs only `sub`, the audience and an
expiry, and is single use when it has a `jti`.

Your subject module's `assertion_principal/2` maps the verified claims
to an account, or refuses with `:error`; Sake will not start with
`trusted_issuers:` and without it (nor without `jose`):

```elixir
@impl true
def assertion_principal(%{"email" => email}, %Sake.Auth.TrustedIssuer{issuer: "https://acme.okta.com"}),
  do: MyApp.Accounts.fetch_user_by_email(email)

def assertion_principal(%{"sub" => "repo:acme/app:" <> _}, %{profile: :workload}),
  do: MyApp.Accounts.fetch_service_account("ci")

def assertion_principal(_claims, _issuer), do: :error
```

Map only claims the issuer vouches for (an identity provider's
`email` is only as good as its own verification of it), and for a
multi-tenant identity provider, check the tenant too. The token's
subject is the account's `id/1`, and `authorize_resource?/2` applies as
for a person. No refresh token is issued: when the token expires, the
client goes back to the identity provider for a new grant, so a person
removed from the directory loses access within one access token
lifetime.

## The extensions in the MCP capabilities

An endpoint with `auth: true` advertises the extensions whose grants
its authorization server offers, in the `extensions` of its
capabilities (`server/discover`, and the `initialize` result on the
legacy revisions), next to the server's own:
`io.modelcontextprotocol/oauth-client-credentials` when your subject
module defines `client_principal/1`, and
`io.modelcontextprotocol/enterprise-managed-authorization` when a
trusted issuer has `profile: :id_jag`. Each has an empty settings
object. A workload's JWT grant and DPoP have no extension identifier;
the authorization server's metadata is where a client learns of them.

Nothing depends on the declaration, since the grants happen at the
token endpoint before any MCP request; it lets a host see what the
server takes. The same server on an endpoint without `auth:` advertises
neither. A mounted server is advertised by the endpoint that serves
it, and a proxy's upstream authorization is the upstream's own.

## DPoP: tokens bound to the client's key

A bearer token works for whoever holds it: one that leaks from a log, a
proxy or a compromised machine can be used anywhere until it expires.
With DPoP (RFC 9449, SEP-1932) the client holds a private key, and
every token is bound to it; whoever steals the token without the key
gets nothing.

It is on by default when the optional `jose` dependency is there, and
costs a client that does not use it nothing:

- **Asking for a bound token.** A token request with a `DPoP` header (a
  proof: a short JWT signed with the client's key, carrying the public
  key, the request's method and URL, a unique `jti` and the time) gets
  tokens bound to that key: `token_type` is `DPoP` and the access token
  record keeps the key's RFC 7638 thumbprint (its `cnf.jkt`). Every
  grant does this: the authorization code, refresh, client credentials
  and JWT bearer grants. A request without a proof gets a bearer token
  as before.
- **Refreshing.** A public client's refresh token is bound to the key
  too, so a refresh needs a proof with that same key. A confidential
  client's refresh token is already bound to its credentials, and each
  refresh binds the new access token to whichever key its proof shows
  (RFC 9449 §5).
- **Using the token.** The MCP endpoint takes a bound token only with
  `Authorization: DPoP <token>` and a fresh proof for that request,
  signed with the bound key and carrying the token's hash (`ath`). The
  same token sent as `Bearer`, a proof made for another method or URL,
  for another token or with another key, one older than five minutes,
  and a proof seen before (the `jti`, kept per key for as long as the
  proof would be accepted) are all refused with a 401.
- **Challenges.** A 401 carries two `WWW-Authenticate` challenges: the
  `Bearer` one as before, and a `DPoP` one with the accepted algorithms
  (`algs`). The one for the scheme the request used comes first, with
  the error: `invalid_token`, `invalid_dpop_proof` or `use_dpop_nonce`.
  A 403 for missing scopes uses the scheme the token came with, so a
  client steps up with DPoP as it would with a bearer token.

```elixir
auth: [
  ...,
  dpop: true,                # the default: DPoP when jose is loaded
  dpop: [nonce: true],       # require a server nonce in every proof
  dpop: [required: true],    # DPoP-bound tokens only (combines with nonce:)
  dpop: false                # bearer tokens only; the DPoP scheme is refused
]
```

**DPoP required.** With `required: true` the server deals in bound
tokens only:

- the token endpoint refuses a request without a proof, on every grant,
  with `invalid_dpop_proof` (before a code or a refresh token is spent);
- the MCP endpoint refuses the `Bearer` scheme, even for an unbound token
  it issued itself, and its 401 carries the `DPoP` challenge alone: a
  challenge names a scheme the server would accept;
- the protected resource metadata says `dpop_bound_access_tokens_required:
  true` (RFC 9728 §2), so a client knows before it asks for a token.

Turning it on is a cut-over: every bearer token issued before stops
working at once, and their clients must authorize again (with DPoP).
Clients that cannot use DPoP cannot use the server at all; Sake's own
client stops with `{:dpop_required, reason}` instead of trying.

A single client can ask for the same (RFC 9449 §5.2): one registered
with `dpop_bound_access_tokens: true` — in its dynamic registration, its
Client ID Metadata Document, or `Sake.Auth.Clients.create/2` — gets its
token requests without a proof refused, whatever the server's setting.
A server with `dpop: false` refuses such a client's token requests with
`invalid_client`, since it cannot bind them.

**Nonces.** A proof's time comes from the client's clock, and a stolen
proof can be replayed to another node of a cluster within its five
minutes. With `nonce: true` the token endpoint and the MCP endpoint
answer a proof without the current nonce with `use_dpop_nonce` and a
`DPoP-Nonce` header (400 at the token endpoint, 401 at the MCP
endpoint), and send the latest nonce on every DPoP answer. A nonce is a
MAC of the time under the Sake secret: nothing is stored, every node
with the same secret accepts it, and it is good for five to ten minutes.
It costs a client one extra round trip now and then.

Without `jose`, the metadata does not offer DPoP, the token endpoint
ignores proofs and issues bearer tokens, and the MCP endpoint refuses the
`DPoP` scheme with `invalid_request`. Asking for it by name (`dpop:
[...]`, `required:` included) without `jose` fails when Sake starts.

## What the metadata says

`/.well-known/oauth-authorization-server` lists only what is configured:
`client_credentials` in `grant_types_supported` when the subject module
defines `client_principal/1`, the JWT bearer grant when an issuer is
trusted (and `authorization_grant_profiles_supported` with the ID-JAG
profile when one of them is an identity provider), and `private_key_jwt`
in `token_endpoint_auth_methods_supported`, with
`token_endpoint_auth_signing_alg_values_supported` (RS256, PS256,
ES256, ES384), when `jose` is there. With DPoP on, both documents (the
authorization server's and the protected resource's) list
`dpop_signing_alg_values_supported`, the same four algorithms, and with
`required: true` the protected resource's says
`dpop_bound_access_tokens_required`.

`client_secret_jwt` is never listed, and the token endpoint refuses its
assertions with `invalid_client`. It is an HMAC keyed with the client
secret, and checking one needs the secret itself, while Sake keeps only
a hash of each secret it issues (see the security guide). A client that
can sign should use `private_key_jwt`; one with a secret sends it with
`client_secret_basic` or `client_secret_post`. `Sake.Client` can still
use `client_secret_jwt` with other servers and identity providers.

## CIMD trust policies

```elixir
auth: [
  ...,
  cimd: [policy: :allow_all]                     # the default: fetch any HTTPS client_id URL
  cimd: [policy: {:allow, ["claude.ai"]}]         # only these hosts
  cimd: [policy: {MyApp.CIMDPolicy, :allowed?}]   # apply(module, fun, [uri])
  cimd: false                                     # refuse every CIMD client_id
]
```

Every fetch is guarded regardless of policy: HTTPS only (unless
`allow_insecure: true`), no credentials in the URL, the host's resolved
addresses must all be public unicast (no loopback, link-local, private,
multicast, reserved or IPv4-translating ranges), no redirects are
followed, the body is capped at 64 KB, and the whole download must finish
within 5 seconds. A document may list at most 10 redirect URIs, and its
optional fields must have their JSON types. The cache holds at most 1000
documents. See `guides/security.md` for what this guard does and does not
protect against.

## DCR and rate limiting

`Sake.Auth.DCR` accepts any `POST /oauth/register` and hands back a public
client, with no authentication of the caller — that is the point of
dynamic registration, and also its risk: an unrate-limited registration
endpoint lets anyone mint clients. Put a rate limit in front of it (by
IP, in your router's pipeline) the same way you would any other
unauthenticated write endpoint. Set `dcr: false` in the auth config to
turn registration off entirely (CIMD and host-registered clients still
work).

## Token lifetimes and rotation

`access_token_ttl` (default 3,600 seconds) and `refresh_token_ttl`
(default 30 days) are configurable per `Sake.Auth.Config`. Every refresh
rotates both tokens (reuse detection): presenting a refresh token a second
time revokes its whole family (every token issued from the same original
code or refresh) rather than just failing that one request — a stolen,
already-used refresh token cannot be replayed to get a fresh pair once the
legitimate client has moved on. Two concurrent refreshes of the same token
both fail closed (the store consumes it atomically); a refresh token
presented by the wrong `client_id` is burned (marked used) even though the
request is denied, so it cannot be retried against the right client
either. An authorization code is single use the same way: presenting it
again revokes every token issued for it, even when the replay races the
request that redeemed it (that request is then refused too). A client may use only the grant types it registered: a client
without `refresh_token` in its `grant_types` gets `unauthorized_client`
for a refresh (dynamic registration grants both when the client names
none).

## The consent page and how to replace it

The default page (`Sake.Auth.Consent.Default`) ships its own inline style
sheet and needs nothing from your app. Replace it with `consent:
MyAppWeb.MCPConsent` in the auth config; your module implements the
`Sake.Auth.Consent` behaviour: `render/1` (client name, host, redirect
host, whether the redirect is a loopback address, the signed-in person's
display string, `{scope, description}` pairs, the `resource` URL, an
opaque `request` blob for a hidden field, the form's `action`, a CSRF
token — empty when your pipeline runs no CSRF protection — and your
issuer's display name) and `render_error/1` (`title`, `message`, `status`) for the
handful of error pages (unknown client, bad redirect, expired request).

Both pages are sent with `x-frame-options: DENY` and
`content-security-policy: frame-ancestors 'none'`, so no other site can
frame them.

Consent is remembered by default (`remember_consent: true`), per person,
client and resource: approving a client once for an endpoint skips the
page on a later request for the same endpoint and the same or a narrower
set of scopes, until the grant is revoked. A request for another endpoint
asks again. Set it to `false` to ask every time.

## The grants API for a settings page

```elixir
Sake.Auth.list_grants(config, subject_id)
# => [%{client_id:, client_name:, scopes:, resource:, granted_at:, family_ids: [...]}]

Sake.Auth.revoke_grant(config, subject_id, client_id)
# revokes every token family the client holds for that person, and forgets its consents
```

The revocation endpoint (`POST /oauth/revoke`) also forgets the consents
the person gave the revoking client, so its next connection asks again.

`list_grants/2` groups a person's live (unexpired, unused) refresh tokens
by client — one row per client, even if it holds tokens for more than one
resource or scope set — for an "apps connected to your account" page.

## `Sake.Auth.prune/1`

```elixir
Sake.Auth.prune(config)
```

Deletes expired codes and tokens, and remembered consents older than the
refresh token lifetime that no live token family still uses. Schedule it — a cron job, an Oban
worker, a periodic `Task` — since neither store does this on its own; the
ETS store especially will otherwise keep every expired row in memory
forever.

## The Ecto migration

```elixir
defmodule MyApp.Repo.Migrations.AddSakeAuth do
  use Ecto.Migration
  def up, do: Sake.Auth.Migration.up()
  def down, do: Sake.Auth.Migration.down()
end
```

Both take `prefix:`. It creates `sake_oauth_clients`, `sake_oauth_codes`,
`sake_oauth_tokens` (with the thumbprint of a token's DPoP key in `jkt`)
and a consents table — string primary keys throughout (hashes and
generated IDs, never the raw secrets). Point the auth config
at it with `store: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}`.

The Ecto store's `put_token` never resurrects a token: it upserts on the
token's `id` with `on_conflict: {:replace_all_except, [:revoked_at,
:used_at]}`, so re-inserting a stale copy of a record (a retried write, a
race with a concurrent revoke) replaces every column *except* those two —
a token already marked revoked or used stays that way no matter what a
later write for the same `id` says about it.

A consumed authorization code is marked used rather than deleted, and kept
until it expires: its row is the fence between issuing the code's tokens
and revoking them when the code is replayed. Issuing locks the row and
inserts the pair in one transaction, unless the row shows the family
revoked; revoking the family marks the row revoked under the same lock
before it sweeps the tokens. Whichever of the two runs second sees what
the other did, so a replay that races the request redeeming the code
never leaves a live pair behind: that request gets `invalid_grant`
instead.

## The ETS store for development

The default, `{Sake.Auth.Store.ETS, []}`, needs no database: an `Agent`
owns a set of ETS tables, which also serializes the operations that must
be atomic (consuming a refresh token, revoking a family) through the
Agent's mailbox rather than a database transaction. It is what `mix dev`
and this package's own test suite use — nothing survives a restart, which
is exactly what you want in development and exactly what you do not want
once real people have connected real clients to a deployed server.
