# Authorization

Sake's authorization server makes your Phoenix (or Plug) app itself the
OAuth 2.1 authorization server for its own MCP endpoint: your login, your
users, no third-party identity provider. See `guides/quickstart.md` for the
five-step setup; this guide is the flow end to end, and the pieces you can
replace or extend.

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
4. Your app's own login runs first if the person is not signed in
   (`Sake.Auth.Authorize` reads the principal through your
   `Sake.Auth.Subject` module and redirects to your login page otherwise).
5. The consent page (`Sake.Auth.Consent.Default`, or your own) shows the
   client's name and the scopes it asked for. Approving redirects back to
   the client with an authorization code.
6. The client exchanges the code (with its PKCE verifier) for an access
   token and a refresh token at `/oauth/token`.
7. The access token is a bearer token on every MCP request from then on;
   the refresh token gets a new pair when the access token expires.

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
  returns a client secret once, for a client that can keep one.

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
`allow_insecure: true`), the host's resolved addresses must all be public
unicast (no loopback, link-local or private ranges), no redirects are
followed, the body is capped at 64 KB, and the request times out after 5
seconds. See `guides/security.md` for what this guard does and does not
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
either.

## The consent page and how to replace it

The default page (`Sake.Auth.Consent.Default`) ships its own inline style
sheet and needs nothing from your app. Replace it with `consent:
MyAppWeb.MCPConsent` in the auth config; your module implements the
`Sake.Auth.Consent` behaviour: `render/1` (client name, host, redirect
host, whether the redirect is a loopback address, the signed-in person's
display string, `{scope, description}` pairs, an opaque `request` blob for
a hidden field, the form's `action`, a CSRF token, and your issuer's
display name) and `render_error/1` (`title`, `message`, `status`) for the
handful of error pages (unknown client, bad redirect, expired request).

Consent is remembered by default (`remember_consent: true`): approving a
client once skips the page on a later request for the same or a narrower
set of scopes, until the grant is revoked. Set it to `false` to ask every
time.

## The grants API for a settings page

```elixir
Sake.Auth.list_grants(config, subject_id)
# => [%{client_id:, client_name:, scopes:, resource:, granted_at:, family_ids: [...]}]

Sake.Auth.revoke_grant(config, subject_id, client_id)
# revokes every token family the client holds for that person, and forgets the consent
```

`list_grants/2` groups a person's live (unexpired, unused) refresh tokens
by client — one row per client, even if it holds tokens for more than one
resource or scope set — for an "apps connected to your account" page.

## `Sake.Auth.prune/1`

```elixir
Sake.Auth.prune(config)
```

Deletes expired codes and tokens. Schedule it — a cron job, an Oban
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
`sake_oauth_tokens` and a consents table — string primary keys throughout
(hashes and generated IDs, never the raw secrets). Point the auth config
at it with `store: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}`.

The Ecto store's `put_token` never resurrects a token: it upserts on the
token's `id` with `on_conflict: {:replace_all_except, [:revoked_at,
:used_at]}`, so re-inserting a stale copy of a record (a retried write, a
race with a concurrent revoke) replaces every column *except* those two —
a token already marked revoked or used stays that way no matter what a
later write for the same `id` says about it.

## The ETS store for development

The default, `{Sake.Auth.Store.ETS, []}`, needs no database: an `Agent`
owns a set of ETS tables, which also serializes the operations that must
be atomic (consuming a refresh token, revoking a family) through the
Agent's mailbox rather than a database transaction. It is what `mix dev`
and this package's own test suite use — nothing survives a restart, which
is exactly what you want in development and exactly what you do not want
once real people have connected real clients to a deployed server.
