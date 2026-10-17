# Changelog

## Unreleased

### Breaking

Authorization now depends on nothing else in Sake (#66): the rest of
Sake calls `Sake.Auth` and `Sake.Client.Auth`, never the other way
round, and a test fails on any call out of them. Nothing changes on the
wire: the 401 and 403 responses are the same bytes.

- `Sake.Client.Challenge` is now `Sake.Auth.Challenge`, a parsed
  `WWW-Authenticate` challenge on the client and the challenge an
  endpoint refuses a token with on the server (`status`,
  `www_authenticate`). Match `%Sake.Auth.Challenge{}` in place of
  `%Sake.Client.Challenge{}`; the old name is gone.
- `Sake.Auth.extension/1` is now `Sake.Protocol.auth_extension/1`.
- `Sake.Auth.Token`, `Sake.Auth.DCR`, `Sake.Auth.Revoke` and
  `Sake.Auth.CIMD` are internal (`@moduledoc false`): mount the token,
  registration and revocation endpoints with `Sake.Router` or
  `Sake.Auth.RouterPlug`. The public modules are listed in the
  `Sake.Auth` documentation.
- `Sake` reads the signing secret (`secret_key_base:`, else
  `config :sake, :secret_key_base`) once, when it starts with `auth:`
  or `external_auth:`, and keeps it in the configuration (the new
  `secret` field of `Sake.Auth.Config` and `Sake.Auth.External`).
  Before, the authorize page and the DPoP nonces read it at every
  request, so a secret set in the application environment after `Sake`
  started was picked up; now it must be there when `Sake` starts.
- `Sake` starts authorization as one child, `Sake.Auth.Supervisor`, in
  place of the store, the CIMD cache, the replay table and the
  introspection cache side by side, and keeps its configuration under
  the `persistent_term` keys `{Sake.Auth, :config}` and
  `{Sake.Auth.External, :configs}` (were `{Sake, :auth}` and
  `{Sake, :external_auth}`). Code that read or wrote those keys, or
  looked for the processes under `Sake.Supervisor`, needs the new ones.

Each OAuth endpoint is now a core and an adapter (#67): the OAuth rules
are pure functions over the configuration and plain data, and the plugs
only parse the request, call them and render the answer (see "Cores
and adapters" in the `Sake.Auth` documentation). The plugs keep their
names and routes, and nothing changes on the wire: every response is
the same bytes. Two undocumented functions moved with the rules:

- `Sake.Auth.Authorize.resource/2` is now
  `Sake.Auth.AuthorizationRequest.resource/2`, and
  `Sake.Auth.Token.grant_types/1` is now
  `Sake.Auth.TokenGrants.grant_types/1`. Both are internal; code that
  called them anyway needs the new names.

### Client

- `Sake.Client.Auth`'s `static: true`, which `Sake.Test` uses, is a
  documented option: the token the `:store` holds is sent as it is, and
  a 401 or a 403 comes back to the caller instead of running the flow.

### Server

- A tool's `{:ok, map_or_list, text: text}` sends `text` (a string or a
  list of `%Sake.Content{}`) as the result's `content` in place of the
  JSON, with `structuredContent` unchanged: the model reads a summary
  while an MCP App renders the full data. Without `text:` nothing
  changes. See "Output and results" in `guides/tools.md`.

### Security

- A modern `subscriptions/listen` stream honours a resource in
  `resourceSubscriptions` on the terms of a legacy `resources/subscribe`:
  the resource declares `subscribe: true`, `:after_list` middleware does
  not hide it, and the token carries its scopes. Before, a token without
  the resource's scopes could follow its updates, and a URI that named
  nothing was acknowledged. Any other URI is now left out of the
  acknowledgement, and the stream gets no updates for it (#33).
- `Sake.Auth.External` refuses a token whose `cnf` binds it any other
  way than DPoP's `jkt`, such as a client certificate (`cnf.x5t#S256`,
  RFC 8705): a 401 like any invalid token, and the refusal reason
  `:unsupported_confirmation`. Sake cannot check such a binding, and
  took the token as an unbound bearer token before. This holds for JWT,
  introspection and callback tokens alike (#71).

## 0.3.0 (2026-10-17)

For hosts that give different people different access, and for
libraries that ship a server their hosts serve or mount. Nothing
changes for a host that uses none of it.

### Authorization

- `c:Sake.Auth.Subject.scopes_for/2` (optional): the scopes a person may
  hold for an endpoint URL, as a list or `:all`. Without it a person
  `authorize_resource?/2` lets through was granted every scope the client
  asked for. With it, the authorize page grants, and the consent page
  shows, only the requested scopes the person may hold, and refuses a
  request left with none (`access_denied`); a machine client's or JWT
  grant's token gets only those of its principal; a refresh renews only
  those the person may still hold, and revokes the grant when none is
  left; and every request narrows the token's scopes to those of the
  principal `fetch/1` loads, so a person whose role changes loses a scope
  at once. The tokens of an external authorization server are not
  narrowed. See "Who may hold which scopes" in `guides/authorization.md`.

### Server

- `mount` takes `only:` or `except:`: a list of the mounted server's
  components, each a module, a tool or prompt name, or a resource URI,
  to mount some of them. An entry that names nothing, a kept tool whose
  MCP App is left out, both options together, and a filter on a server
  that lists a proxy's upstream are compile errors. See "Mounting some of
  a server" in `guides/composing.md`.

### Documentation

- `guides/libraries.md`: shipping a server in a library, with Sake as an
  optional dependency, configuration read at runtime, an opaque
  principal, namespaced scopes, how the host serves or mounts it, and
  names as the library's API.

## 0.2.0 (2026-10-17)

The first release meant for use: a server for both protocol eras, an
OAuth 2.1 authorization server on the host's own login (or the host's
own authorization server instead), and a client that runs the MCP
authorization flow itself.

### Server

- `Sake.Server`, `Sake.Tool`, `Sake.Resource`, `Sake.Prompt`: declare
  tools, resources (fixed and templated, with subscriptions and
  completion) and prompts with a small DSL, compiled to JSON Schema.
- `Sake.Plug`: one endpoint serving the modern (2026-07-28), stateless
  protocol and the three handshake-era revisions (2025-11-25, 2025-06-18,
  2025-03-26) side by side, with Server-Sent Events streaming, progress
  and log notifications, and Origin checking. With `pubsub:` on the
  `Sake` child, notifications, and a legacy session's subscriptions and
  answers to the server's requests, reach whichever node holds the
  stream or the waiting handler.
- `Sake.Router`: Phoenix router macros for the well-known, OAuth API,
  authorize, and endpoint routes, including under a scope with a dynamic
  tenant segment.
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
  `notifications/tasks` on `subscriptions/listen`, binding to the
  principal, server, OAuth client and resource that created the task (and
  to the tool's scopes on every access), a cap on each owner's live
  tasks (`max_per_principal`), and telemetry. `Sake.Tasks.Store.ETS`
  (default) and `Sake.Tasks.Store.Ecto` with `Sake.Tasks.Migration` for
  several nodes. A tool's optional `prepare/2` runs in the request before
  `execute/2`.
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
- `Sake.Stdio` and `mix sake.stdio`: the same server over standard input
  and output, on both eras, with concurrent requests, cancellation,
  progress and log notifications, elicitation, sampling and roots,
  subscriptions, tasks, and shutdown when standard input closes.
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
- `Sake.Proxy`: another MCP server's tools, resources and prompts,
  served (or mounted) as the server's own and forwarded with
  `Sake.Client`, over HTTP or to a stdio subprocess, to and from either
  era. Upstream sessions per principal and credential, with a fixed
  token, the client's own authorization, or a `credentials/1` callback
  that lets each user act as themselves upstream; a refused session is
  opened again once. `only`/`except` filters, a `scope` and a per-name
  `scopes` map, and middleware decide what each principal sees. Lists
  cached by the upstream's `ttlMs`; progress and log messages, and
  elicitation, sampling and roots requests forwarded in every era
  combination, with the upstream's `requestState` carried inside the
  proxy's own, signed and bound to the principal; an upstream's task
  re-issued as the proxy's own; list changes and subscribed resource
  updates followed upstream and broadcast, renamed under a mount's
  prefix. Upstream names never shadow local ones, and upstream
  definitions are validated. See `guides/composing.md`.
- `config :sake, :json_library`: the library Sake encodes the host's data
  with, `JSON` (the default) or `Jason` (for structs that derive
  `Jason.Encoder`, such as many Ecto schemas), or any module with
  `encode!/1` and `encode_to_iodata!/1`, checked when Sake starts. A
  struct the library cannot encode raises with a pointer to the setting.
  Decoding, tokens and OAuth responses always use `JSON`.

### Authorization

- An OAuth 2.1 authorization server on the host application's own login:
  bearer token validation, `/.well-known` discovery, Client ID Metadata
  Document support, dynamic client registration (RFC 7591, its unused
  clients pruned after `unused_client_ttl`), the authorize/consent flow,
  the token endpoint (authorization code + PKCE, refresh token rotation
  with reuse detection and family revocation, and a replayed code
  revoking its family atomically with its issuance), and revocation
  (RFC 7009). Consent is remembered per person, client and resource; a
  subject module's optional `authorize_resource?/2` refuses a tenant the
  person does not belong to, when authorizing and on every refresh.
  Works under a generated Phoenix endpoint (its parsed body, its
  `protect_from_forgery`).
- `Sake.Auth.Store.ETS` (development) and `Sake.Auth.Store.Ecto`
  (production, with `Sake.Auth.Migration`) token/client/code/consent
  stores, plus a grants API for a settings page and `Sake.Auth.prune/1`
  for expired rows.
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
  module's `assertion_principal/2`; a grant may stay valid for no longer
  than its issuer's `max_lifetime:` (five minutes for an ID-JAG, an hour
  for a workload token, by default), and a client assertion for no longer
  than `max_assertion_lifetime:` (five minutes). Neither grant issues a
  refresh token; key sets are fetched and cached, `jti`s are remembered
  against replay, and the metadata advertises only what is configured.
  An endpoint with `auth: true` advertises the extensions of the grants
  offered in the `extensions` of its capabilities (`server/discover` and
  the legacy `initialize` result). Signed JWTs need the optional `jose`
  dependency.
- Single-use JWTs (client assertions, JWT grants, DPoP proofs) are
  remembered in the replay store, the `Sake` child's `replay:` (by
  default the `auth:` store): with `Sake.Auth.Store.Ecto`, a table every
  node of a cluster shares.
- DPoP (RFC 9449, SEP-1932), sender-constrained tokens, on both sides and
  both eras. The authorization server binds the tokens of a request that
  carries a proof to the proof's key (`token_type: DPoP`, the key's
  RFC 7638 thumbprint kept as the token's `jkt`), on every grant; a
  public client's refresh token is bound too, a confidential client's
  stays bound to its credentials. The MCP endpoint takes a bound token
  only with the `DPoP` scheme and a proof for that request (method, URL,
  token hash, key, age, single use), and refuses it as a bearer token;
  its 401 challenges both schemes. With `dpop: [nonce: true]` both
  require stateless server nonces (`use_dpop_nonce`, `DPoP-Nonce`). The
  metadata lists `dpop_signing_alg_values_supported`. The client (`dpop:`
  in `auth:`, `:auto` by default) asks for bound tokens when the
  authorization server offers DPoP, with one P-256 key per authorization
  kept with the token (as PEM, in the store too), sends a proof with
  every token request and every MCP request (POST, the legacy GET stream
  and DELETE), keeps a refresh on the same key, and answers nonce
  challenges from both servers without counting them as authorizations.
  `dpop: [required: true]` takes bound tokens only (proof-less token
  requests and the Bearer scheme are refused, the resource metadata says
  `dpop_bound_access_tokens_required`, and a client that cannot use DPoP
  stops with `{:dpop_required, reason}`); a client registered with
  `dpop_bound_access_tokens` (RFC 9449 §5.2) gets the same for itself. A
  `Sake.Proxy` gets it through `connect: [auth: ...]`. DPoP needs the
  optional `jose` dependency; without it the server neither offers nor
  accepts it and the client never uses it.
- `Sake.Auth.External`: an endpoint whose tokens come from an
  authorization server Sake does not run, an in-app provider
  (ExOauth2Provider, Boruta) or an identity provider (Keycloak, Auth0,
  Okta, Entra ID, ...), named in `external_auth:` of the `Sake` child and
  on the endpoint (`auth: :keycloak`); `Sake.Auth` is then not needed, or
  runs side by side for other endpoints (`resources:` says which path is
  whose). Tokens are verified as JWT access tokens (RFC 9068: signature
  with the issuer's keys from `jwks:`, `jwks_uri:` or its metadata, with
  one refetch for an unknown key ID; `iss`, `aud`, `exp`, `nbf`, a
  configurable `typ`), by token introspection (RFC 7662, the resource's
  credentials, a short cache keyed by a token digest that honours
  `exp`), or by the host's `verify_token/2` callback. A token must carry
  the endpoint's URL (or a configured audience) in `aud` unless
  `audiences: :any` says otherwise. It becomes the same
  `Sake.Auth.TokenRecord` (with `issuer` and `claims`), with its
  scopes (`scope` or `scp`), its client, its subject (none for a machine
  client) and its DPoP binding (`cnf.jkt`, checked with a proof, nonces
  included); the principal is `principal:`'s, the callback's, or the
  claims. The protected resource metadata names the external issuer,
  scope checks and step-up challenges are unchanged, tasks and request
  states are bound to the issuer, and the capabilities declare only the
  extensions configured. Refusals are the telemetry event `[:sake, :auth,
  :external, :refused]` with their reason. Without `Sake.Auth`,
  `/.well-known/oauth-authorization-server` answers 404.

### Client

- `Sake.Client`: a functional client for both protocol eras, with era
  probing, elicitation via `on_input`, sampling and roots via `sampling:`
  and `roots:`, log messages at `log_level:` (and `set_log_level/2`),
  tool calls followed through tasks (and `call_tool_async/3`,
  `get_task/2`, `update_task/3`, `cancel_task/2`), MCP Apps via
  `ui: true`, and a parsed `WWW-Authenticate` challenge on a 401.
  Server-Sent Events are read with any line end the SSE spec allows, and
  `max_response_size:` (16 MiB by default) bounds a JSON body, an event
  still being received, and a stdio line.
- `Sake.Client.connect/2` launches a stdio server with
  `{:stdio, command, args}`, probing the era as the stdio transport asks;
  `on_notification:` sees a call's notifications on either transport.
- `Sake.Client.request/4` returns a result as the server sent it (an
  input-required result, a task), and `Sake.Client.listen/3` follows a
  server's list changes and resource updates on both eras. An answering
  function may throw to abandon a legacy call; a stdio session's
  requests go out under ids of the transport's own. A legacy GET stream
  sends a comment as soon as it opens.
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
  :client_credentials` (`client_secret_basic`, `client_secret_post`,
  `private_key_jwt` or `client_secret_jwt`), `grant: :jwt_bearer` (a
  workload's JWT) and `grant: :enterprise` (the RFC 8693 token exchange
  of an ID token for an ID-JAG at the identity provider, then the JWT
  bearer grant), renewing an expiring token by running the grant again.
  With SAML single sign-on, `grant: :enterprise` takes `saml_assertion:`
  in place of `id_token:`: the assertion is exchanged at the identity
  provider for a refresh token, and that for the ID-JAG
  (draft-ietf-oauth-identity-assertion-authz-grant §4.5); the refresh
  token is kept (in `Sake.Client.Auth.Store` too, under `{:idp, issuer}`)
  and stands in for the assertion until it expires or is refused.
  `client_secret_jwt` (RFC 7523 §2.2, HS256 over the client secret, with
  no `jose` needed) authenticates the client at the authorization server
  (`token_endpoint_auth_method: "client_secret_jwt"`, or when the server
  lists it as its only secret method) and at the identity provider. The
  authorization server does not offer `client_secret_jwt`: it keeps only
  a hash of each secret, and verifies no HMAC. `assertion_audience:`
  (`:issuer`, the default, `:token_endpoint` or a string), in `auth:`
  and in `idp:`, sets the `aud` of the client's `private_key_jwt` and
  `client_secret_jwt` assertions; `idp: [saml_scope: [...]]` is the
  `scope` of the SAML exchange (none by default). `:client_credentials` and
  `:enterprise` declare their extension in the client's capabilities
  (per request on 2026-07-28, in `initialize` on the legacy revisions).

### Testing, observability and operations

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
- A warning, once a node joins a cluster, for each piece of state Sake
  keeps on that node only (the ETS stores, a replay table without a
  shared store, streams without `pubsub:`), and a "Running on several
  nodes" guide.
- A development server (`mix dev`) and an end-to-end test driving the
  whole OAuth-to-tool-call flow through it.
- The official MCP conformance suite (0.2.0-alpha.12) wired into CI: the
  server and client scenarios of 2025-06-18, 2025-11-25 and 2026-07-28,
  the authorization-server scenarios against the development server's own
  authorization server, and, as a separate step, the extension scenarios.
  Its baselines list the known, documented gaps (SSE resumability, the
  client's standalone GET stream, answers sent without a request state);
  every `auth/*` client scenario, every tasks extension scenario and
  every client auth extension scenario (DPoP's included) passes.
- CI runs the tests on Elixir 1.18 (OTP 27), 1.19 (OTP 28) and 1.20
  (OTP 29).

### Security

Fixed before this release, after a review of the authorization server,
tasks and transports:

- Tasks are bound to the server, OAuth client and resource they were
  created through, and to the tool's scopes, as well as to their
  principal: the same person's token for another client, resource or
  server could read, answer or cancel a task. (#30)
- A replayed authorization code that raced the request redeeming it
  could leave a live token pair behind; issuing and revoking now meet on
  the consumed code's row. (#38)
- A multi round-trip request's signed state bound its principal by a
  short hash, so two principals could share a state; it now binds the
  full owner (principal, server, client and resource). (#47)
- A refresh now asks the subject module again: a person removed from a
  tenant, or whose account no longer loads, could renew a grant
  indefinitely. The family is revoked instead. (#48)
- An internal failure no longer sends its message to the client, which
  could carry whatever the failing code had in it: the client gets
  `"The request failed."` and an `errorId` that the log line and the
  request's span carry too. (#49)
- Single-use JWTs (client assertions, JWT grants, DPoP proofs) are
  remembered in a store every node can share, so a cluster no longer
  accepts the same JWT once per node. (#50)
- The ETS store kept an entry, never removed, for every unknown code a
  client presented. (#51)
- A JWT grant or a client assertion may stay valid only for a bounded
  time, which also bounds how long its `jti` must be remembered. (#52)
- A token request's DPoP proof is recorded only once its client is
  authenticated, so requests without credentials cannot fill the replay
  store. (#53)
- A refresh racing a reuse of the same refresh token could leave the
  new pair live; the pair is now stored under a lock that revocation
  takes too. (#55)
- `Sake.Client` bounds what one response may buffer, and reads SSE with
  every line end, so a server cannot make it grow without limit. (#57)
- Dynamically registered clients that nothing came to use are pruned,
  since registration is an unauthenticated write. (#58)
- Each owner's live tasks are capped. (#59)

## 0.1.0 (2026-10-15)

An early preview, retired; use 0.2.0.
