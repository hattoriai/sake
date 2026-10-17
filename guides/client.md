# The client

`Sake.Client` talks to any MCP server (Sake-built or not) over Streamable
HTTP or stdio, on either protocol era, and runs the MCP authorization
flow itself when a server asks for it over HTTP (see "Authorization"
below).

```elixir
{:ok, session} = Sake.Client.connect("https://mcp.example.com/mcp", headers: [{"authorization", "Bearer " <> token}])
{:ok, tools, session} = Sake.Client.list_tools(session)
{:ok, result, session} = Sake.Client.call_tool(session, "search", %{"query" => "x"})
IO.puts(result.text)
```

Every call is functional: it returns `{:ok, value, session}` (or
`{:error, reason, session}`), and the *returned* session — not the one you
passed in — carries state that changed (the negotiated revision, a legacy
session ID, the next JSON-RPC id). `connect/2` is the one exception,
returning `{:ok, session}` (no prior session to update).

## Calls

`list_tools/1`, `call_tool/3`, `call_tool_async/3`, `get_task/2`,
`update_task/3`, `cancel_task/2`, `set_log_level/2`, `list_resources/1`,
`list_resource_templates/1`, `read_resource/2`, `list_prompts/1`,
`get_prompt/3`, `complete/4` (`{:prompt, name}` or `{:resource, uri}`, an
argument name, and the partial value), `ping/1`, `discover/1` (the modern
handshake call directly, if you need it), and `close/1` (sends a `DELETE`
on a legacy session, whatever the server answers; a no-op on modern, which has none to close; stops
a stdio server).

## Stdio

`connect/2` takes `{:stdio, command, args}` in place of a URL, launches
the server as a subprocess, and talks to it over its standard input and
output; every call works the same way. See `guides/stdio.md` for the
options, the era probe over stdio, and how `close/1` stops the server.

```elixir
{:ok, session} = Sake.Client.connect({:stdio, "my-mcp-server", ["--verbose"]}, env: %{"TOKEN" => token})
```

`max_response_size:` (bytes, 16 MiB by default) bounds what the client
holds of one response: a JSON body or a Server-Sent Event still arriving
over HTTP, which end the request with `{:error, :response_too_large}`,
and a line over stdio, which is dropped with a warning. Raise it for a
server whose results are larger.

The client encodes its requests with `config :sake, :json_library`
(`JSON` by default; see `guides/tools.md`), so arguments holding structs
that derive only `Jason.Encoder` need `config :sake, :json_library,
Jason`.

`call_tool/3` returns a `Sake.Client.ToolResult`: `content` (a list of
`Sake.Content.t()`), `structured` (the tool's `structuredContent`, if any),
`is_error` (the tool itself failed — still a successful RPC), `text` (every
text content block joined), and `meta` (the result's `_meta`).

## Era probing

`connect/2` with no `era:` option tries the modern handshake
(`server/discover`) first. An error only a modern server sends (`-32020`,
`-32021`, `-32022`) is reported as-is, with one exception: an unsupported
version error (`-32022`) whose list of supported revisions includes the
one the client sent is retried once, and only a second refusal comes back
as `{:error, {:no_common_version, supported}}`. "Method not found" (`-32601`) or
"invalid params" (`-32602`) — over HTTP 200 or a 4xx — or a failure with
no JSON-RPC error at all means "this is a legacy server", and the client
retries with the legacy `initialize` handshake. Force one era directly
with `era: :modern` or `era: :legacy` (plus `legacy_version:` to pick which
of the three legacy revisions to offer) when you already know which the
server speaks — skipping the probe saves a round trip.

## `on_input`

```elixir
on_input = fn requests, _session ->
  Map.new(requests, fn {key, %{"params" => %{"message" => message}}} ->
    IO.gets(message <> " ")
    |> String.trim()
    |> then(&{key, %{"action" => "accept", "content" => %{"name" => &1}}})
  end)
end

{:ok, session} = Sake.Client.connect(url, on_input: on_input)
```

Passing `on_input:` also turns on the `elicitation` capability the client
advertises (without it, capabilities default to `%{}` — a client that
cannot answer has no business claiming it can). `requests` is a map from
a request key to `%{"method" => "elicitation/create", "params" => ...}`;
your function returns a map from the same keys to
`%{"action" => "accept" | "decline" | "cancel", "content" => %{...}}`
(content only matters for `"accept"`). On a modern connection, a call that
elicits blocks inside the library and retries with `inputResponses`
automatically — `on_input` just needs to answer the questions it is
handed. On a legacy connection, the request arrives keyed by the server
handler's own key when the server sets one (`_meta["ai.hattori.sake/key"]`,
which a Sake-built server always does — see `guides/tools.md`), or by the
fixed key `"legacy"` from a server that does not.

Without `on_input`, every elicitation is answered `"cancel"` automatically
— a script that never expects to be asked anything still behaves
correctly rather than hanging.

## `sampling:` and `roots:`

```elixir
sampling = fn %{"messages" => messages, "maxTokens" => max}, _session ->
  case MyLLM.complete(messages, max_tokens: max) do
    {:ok, text} ->
      {:ok, %{"role" => "assistant", "content" => %{"type" => "text", "text" => text}, "model" => "my-model"}}

    {:error, _} ->
      {:error, %{"code" => -1, "message" => "Sampling declined"}}
  end
end

{:ok, session} =
  Sake.Client.connect(url,
    sampling: sampling,
    roots: [%{"uri" => "file:///home/ana/project", "name" => "Project"}]
  )
```

`sampling:` answers `sampling/createMessage` requests: a function of the
request's params and the session, returning `{:ok, result}` (a
`CreateMessageResult` map) or `{:error, error}` (a JSON-RPC error map).
`roots:` answers `roots/list`: a list of root maps, or a function of the
session that returns one. Each turns on its capability (`sampling`, and
`roots` with `listChanged: false`) the way `on_input:` turns on
`elicitation`. Requests reach them however the server asks — in a modern
retry, on a legacy call's stream, or from a task.

A request nothing can answer (a server should not send one, but a foreign
server might) is left out of a modern retry, and gets a "method not
found" error on a legacy stream; an elicitation is still answered
`"cancel"`.

## Tasks

On the modern protocol the client declares the tasks extension on every
request (`tasks: false` leaves it out), so a server may make a task of a
tool call (see `guides/tasks.md`). `call_tool/3` hides this: it polls the
task at the interval the server suggests, answers its input requests
through `tasks/update` with the same routing as above (each question
once), and returns the final result — `{:error, {:rpc, error}, session}`
for a failed task, `{:error, :cancelled, session}` for a cancelled one.
A task still running after `task_timeout:` (ms, default five minutes) is
cancelled and returned as `{:error, :task_timeout, session}`.

To manage tasks yourself, `call_tool_async/3` returns
`{:ok, {:task, task}, session}` (or the plain result when the server
answered without a task), and `get_task/2`, `update_task/3` and
`cancel_task/2` drive it.

## MCP Apps

`ui: true` declares the MCP Apps extension (`io.modelcontextprotocol/ui`)
on both eras, as a host that renders apps does. The server then lists the
tools only an app calls and its UI resources, `list_tools/1` puts each
tool's app in `spec.ui` (the `ui://` URI) and `spec.visibility` (`[:model,
:app]`, `[:app]` or `[:model]`), and `read_resource/2` returns the app's
document with its `_meta` (the CSP and permissions it asks for). Without
it, a Sake server lists its tools as plain tools. See `guides/apps.md`.

## `on_notification`

```elixir
on_notification = fn
  "notifications/progress", %{"progress" => p} = params -> IO.puts("#{p}/#{params["total"]}")
  _method, _params -> :ok
end

{:ok, session} = Sake.Client.connect(url, on_notification: on_notification)
```

The function sees every notification the server sends during a call: its
progress (the client then asks for progress on every request, with the
request's id as the token) and log messages. Its return value is
ignored, and it runs in the calling process while the call waits.

Log messages come only from a server that was asked for them: pass
`log_level:` (`"debug"` to `"emergency"`) to `connect/2`, or change it
later with `set_log_level/2`. On the modern protocol the level travels in
every request's `_meta`; on a legacy session the client sends
`logging/setLevel`, right after the handshake for `log_level:`.

## Following the server's changes

`listen/3` follows what the server announces between calls, until it
ends the stream: list changes, and the updates of the resources the
filter names.

```elixir
filter = %{"toolsListChanged" => true, "resourceSubscriptions" => ["issue://1"]}

Task.start_link(fn ->
  Sake.Client.listen(session, filter, fn method, params -> send(owner, {method, params}) end)
end)
```

On the modern protocol it is a `subscriptions/listen` request; on a
legacy session, the session's GET stream (over stdio, what the server
sends between calls), with a `resources/subscribe` for each URI. It
blocks while the stream lasts, so run it in a process of its own, and
stop that process to stop listening.

## Raw requests

`request/4` sends any request and returns its result as the server sent
it, with the session's `_meta`, headers and authorization: an
input-required result or a task comes back as it is, for you to answer
(retry with `inputResponses` and the `requestState`) or follow
(`get_task/2`). `Sake.Proxy` forwards calls this way.

```elixir
{:ok, %{"resultType" => "input_required"} = result, session} =
  Sake.Client.request(session, "tools/call", %{"name" => "confirm", "arguments" => %{}})
```

## Authorization

Pass `auth:` and the client runs the MCP authorization flow itself
whenever a server answers 401:

```elixir
{:ok, session} =
  Sake.Client.connect("https://mcp.example.com/mcp",
    auth: [authorize: &Sake.Client.Auth.Browser.authorize/1]
  )
```

On the 401, the client:

1. reads the `WWW-Authenticate` challenge and fetches the protected
   resource metadata (RFC 9728) from its `resource_metadata` URL, or, when
   the challenge has none, from the well-known URI with the endpoint's
   path inserted, then the one at the root. The document must be about
   this endpoint: its `resource` must be the endpoint's URL or a path
   prefix of it on the same origin, or the flow stops;
2. takes the first authorization server the document lists and fetches
   its metadata, trying RFC 8414 and OpenID Connect Discovery URLs in the
   specification's order (with an issuer path: path-inserted RFC 8414,
   path-inserted OpenID Connect, then OpenID Connect appended). A document
   whose `issuer` is not exactly that server's is refused, and so is a
   server that does not list `S256` among its PKCE methods;
3. picks a client identity (below);
4. sends the person to the authorization endpoint with a PKCE S256
   challenge, a random `state`, the `resource` parameter (RFC 8707: the
   identifier from the resource metadata, exactly as published) and the
   scopes (below);
5. checks the answer before it uses the code: an `iss` parameter must be
   the server's issuer, character for character, and must be there at all
   when the server advertises
   `authorization_response_iss_parameter_supported` (RFC 9207); the
   `state` must match. A response from the wrong server is not acted on,
   not even to report its `error`;
6. exchanges the code (with the PKCE verifier and the same `resource`)
   for a token, and sends the original request again with it:
   `Authorization: Bearer`, or `Authorization: DPoP` and a proof when the
   token is bound to the client's key (below).

Every later request carries the token. A token about to expire is
refreshed before it is sent; on a 401 the refresh token is tried before
the whole flow runs again. A server without resource metadata at all is
treated as a 2025-03-26 one, its own authorization server, with the
default `/authorize`, `/token` and `/register` endpoints on its origin
when it publishes no metadata either.

Every endpoint of the authorization server (and the metadata documents)
must be HTTPS, or plain HTTP to a loopback host; the flow's own requests
follow no redirects. Options in `req:` apply to these requests too.

### The client's identity

In the specification's order of preference:

- **Pre-registered credentials** — `client_id:` (and `client_secret:` for
  a confidential client). The token endpoint authentication method is
  chosen from the server's `token_endpoint_auth_methods_supported`
  (`client_secret_basic`, then `client_secret_post`, or `none` without a
  secret); `token_endpoint_auth_method:` overrides it. Pre-registered
  credentials belong to one authorization server: `issuer:` names it, and
  without it they are bound to the first one they are used with. They are
  never offered to another — the flow stops with
  `{:client_issuer_mismatch, bound, new}` instead.
- **A Client ID Metadata Document** — `client_metadata_url:`, the HTTPS
  URL of a JSON document you host, used as the `client_id` when the server
  advertises `client_id_metadata_document_supported`. The document's
  `redirect_uris` must include the `redirect_uri:` the client uses.
- **Dynamic Client Registration** (RFC 7591) — when the server has a
  `registration_endpoint`. The client registers its redirect URI, the
  authorization code and refresh token grants, `application_type`
  `"native"` (or `"web"` for an HTTPS redirect URI on a real host), and a
  public client (`none`) when the server takes one, else the secret
  method it supports. A registration is kept per authorization server and
  never presented to another; when the resource moves to a new server,
  the client registers again there.

### The interactive step

`authorize:` is a function of the authorization URL that returns
`{:ok, params}` — the query parameters the server sent to the redirect
URI — or `{:error, reason}`. Two come with Sake:

- `Sake.Client.Auth.Browser.authorize/1` (the default) opens the URL in
  the system browser and waits for the redirect on a one-shot listener at
  `redirect_uri:` — by default `http://127.0.0.1:33418/callback`; any
  loopback address with a port you choose works. It gives up after five
  minutes (`&Sake.Client.Auth.Browser.authorize(&1, timeout: ...)`), and
  `open:` replaces the system opener, to print the URL for a person on
  another machine, say.
- `Sake.Client.Auth.Headless.authorize/1` GETs the URL and reads the
  redirect's `Location` without following it, for an authorization
  server that approves without a person: a test server, or the
  conformance suite's.

Your own function can do anything else — show the URL in your app's UI
and wait for the callback on your web server, for instance.

### Pushed authorization requests

When the authorization server's metadata lists a
`pushed_authorization_request_endpoint` (RFC 9126), the client pushes
the authorization request there instead of putting it in the URL: step 4
above becomes a POST of the same parameters, authenticated as the token
request is (with a DPoP proof when the client uses DPoP, which binds the
code to its key), and the person is sent to the authorization endpoint
with only the `client_id` and the `request_uri` the server returned. The
parameters never pass through the browser, and the answer is checked as
before.

```elixir
# Never push, unless the server requires it.
Sake.Client.connect(url, auth: [par: false])
```

`par: false` (the default is `:auto`) puts the request in the URL again,
except for a server whose metadata says
`require_pushed_authorization_requests`: that one gets it pushed anyway,
since it would refuse anything else. A push the server refuses ends the
flow with `{:error, {:auth, {:par_failed, status, body}}}`; one refused
for its DPoP nonce is sent again with it, as a token request is.

### A person without a browser here: the device grant

On a machine where no browser can open, a CLI over SSH or a headless
agent, `grant: :device` runs the device authorization grant (RFC 8628)
in place of the code flow: the client shows the person a code and a URL,
and they enter the code on any device where they can sign in, their
laptop or their phone.

```elixir
Sake.Client.connect(url,
  auth: [
    grant: :device,
    device_prompt: fn %{user_code: code, verification_uri: uri} ->
      IO.puts("To connect, open #{uri} and enter #{code}")
    end
  ]
)
```

Discovery is the same, but the authorization server's metadata needs a
`device_authorization_endpoint` (and a token endpoint, but no
authorization endpoint and no PKCE); without one the flow stops at once
with `{:error, {:auth, :no_device_endpoint}}`. The client identity is
chosen as above, and a dynamic registration asks for the device code
and refresh token grants, with no redirect URI.

`:device_prompt` receives `user_code`, `verification_uri`,
`verification_uri_complete` (the URL with the code in it, for a link or
a QR code, or nil) and `expires_in`; the default,
`Sake.Client.Auth.Device.prompt/1`, logs them. The client then polls
the token endpoint every `interval` seconds the server gave (five when
it gave none), five seconds more after each `slow_down`, until the
person decides: a denial is `{:error, {:auth, :access_denied}}`, and a
code that expired first `{:error, {:auth, :expired_token}}`. The tokens
are DPoP-bound as below, and refreshed as the code flow's are; a
step-up, or a 401 the refresh token does not cure, shows the person a
new code.

### Grants without a person

`grant:` replaces the browser with a grant a program runs on its own.
Discovery is the same (resource metadata, then the authorization
server's, which then needs only a token endpoint); no client registers
dynamically.

```elixir
# A service acting as itself (the client credentials extension), with a
# secret...
auth: [grant: :client_credentials, client_id: "svc", client_secret: secret]

# ...or with a private key: it signs a one-minute assertion for the
# authorization server's issuer on every token request (private_key_jwt).
auth: [grant: :client_credentials, client_id: "svc", private_key: File.read!("svc.pem")]

# A workload presenting its platform's JWT (RFC 7523 JWT bearer grant);
# a function gets one for the discovered issuer and resource.
auth: [grant: :jwt_bearer, client_id: "ci", assertion: fn %{issuer: aud} -> MyApp.Platform.id_token(aud) end]

# Enterprise-managed authorization: the person's ID token from your own
# single sign-on is exchanged at their identity provider for an ID-JAG,
# which the authorization server takes as a JWT bearer grant.
auth: [
  grant: :enterprise,
  client_id: "agent",
  client_secret: agent_secret,
  id_token: id_token,
  idp: [issuer: "https://acme.okta.com", client_id: "agent-at-okta", client_secret: okta_secret]
]

# The same with SAML single sign-on: the assertion in place of the ID token.
auth: [
  grant: :enterprise,
  client_id: "agent",
  saml_assertion: fn _target -> MyApp.SSO.saml_assertion(conn) end,
  idp: [issuer: "https://acme.okta.com", client_id: "agent-at-okta", client_secret: okta_secret]
]
```

The token exchange (RFC 8693) asks the identity provider for an ID-JAG
with the authorization server's issuer as `audience`, the endpoint's
resource identifier as `resource` and the scopes chosen as below; `idp:`
takes the provider's `token_endpoint:` directly, or its `issuer:` to read
it from the provider's metadata. Obtaining the ID token is your single
sign-on's business: pass it, or a function that returns `{:ok, token}`
when the flow needs one.

With SAML single sign-on, pass `saml_assertion:` instead of `id_token:`:
the SAML 2.0 assertion, base64url-encoded as RFC 8693 expects it, or a
function returning `{:ok, assertion}`. The identity provider needs
`issuer:` then. The client follows §4.5 of
draft-ietf-oauth-identity-assertion-authz-grant: it first exchanges
the assertion at the provider for a refresh token (a token exchange
with `subject_token_type` `urn:ietf:params:oauth:token-type:saml2`,
`requested_token_type` `urn:ietf:params:oauth:token-type:refresh_token`
and the provider's issuer as `audience`, and no `scope` unless
`idp: [saml_scope: [...]]` gives one; some providers issue a refresh
token only when `offline_access` is asked for, so
`saml_scope: ["offline_access"]` is the setting for them), then
exchanges that refresh
token for the ID-JAG, as it would an ID token. Sake never reads the
assertion; it passes it on as it is.

The refresh token is kept, in the session and in the `store:`, bound to
the provider and to the client id there. The next authorizations (a
renewal, a step-up, a new session with the same store) exchange it for
a new ID-JAG and need no assertion, until it expires (the `expires_in`
of the provider's answer) or the provider refuses it with
`invalid_grant`; then the assertion is traded again, once. A function
`saml_assertion:` is therefore only called when there is no usable
refresh token. A refusal of the assertion itself comes back as
`{:saml_exchange_failed, status, body}`.

`private_key:` is a PEM RSA (2048 bits or more), P-256 or P-384 private
key, signing RS256, ES256 or ES384, or `{pem, alg}` for another algorithm
(PS256); it needs the optional `jose` dependency (`{:jose, "~> 1.11"}`).
Pre-registered credentials stay bound to their authorization server, as
above.

`client_secret_jwt` (RFC 7523 §2.2 with an HMAC) proves the secret
without sending it: the client signs the same one-minute assertion as
`private_key_jwt` (the client as `iss` and `sub`, the server's issuer as
`aud`, a unique `jti`) with HS256 keyed by `client_secret:`. It needs no
`jose`, and a secret of at least 32 bytes (RFC 7518 §3.2). Ask for it
with `token_endpoint_auth_method: "client_secret_jwt"` at the
authorization server, or `idp: [token_endpoint_auth_method:
"client_secret_jwt"]` at the identity provider, where some providers
require it for the token exchange; it is also chosen, at either, when
the metadata lists it and neither `client_secret_basic` nor
`client_secret_post`. Sake's own authorization server does not take it
(see the security guide).

The `aud` of a client assertion, `private_key_jwt` or
`client_secret_jwt`, is the server's issuer identifier by default, as
draft-ietf-oauth-rfc7523bis asks: an assertion made for one server's
issuer cannot be replayed at another's token endpoint. Some servers
want their token endpoint URL instead (Okta's `private_key_jwt`
documentation, for one), so `assertion_audience:` picks it:

```elixir
auth: [..., assertion_audience: :issuer]           # the default
auth: [..., assertion_audience: :token_endpoint]   # the token endpoint's URL
auth: [..., assertion_audience: "https://..."]     # this exact value
idp: [..., assertion_audience: :token_endpoint]    # the same, at the identity provider
```

At an identity provider given by `token_endpoint:` alone, the default
`aud` is that endpoint, since no issuer is known.

`grant: :client_credentials` and `grant: :enterprise` declare their
extension (`io.modelcontextprotocol/oauth-client-credentials`,
`io.modelcontextprotocol/enterprise-managed-authorization`) in the
client's capabilities: in every request's `_meta` on 2026-07-28 and in
`initialize` on the legacy revisions, next to the tasks and MCP Apps
extensions (`Sake.Protocol.auth_extension/1` gives the identifiers).
`grant: :jwt_bearer` declares none, since the workload identity grant
has no extension identifier, and neither does DPoP.

None of these grants returns a refresh token. An expiring token is
replaced by running the grant again (straight at the token endpoint it
came from), a 401 runs it after discovery, and a 403
`insufficient_scope` runs it for the union of the scopes. A refused
grant comes back as `{:error, {:auth, {:token_failed, status, body}}}`
(`{:token_exchange_failed, ...}` from the identity provider): the client
does not retry it, nor fall back to another grant.

### Scopes

The first authorization asks for the challenge's `scope` when it has one,
else every scope in the resource metadata's `scopes_supported`, else no
`scope` parameter at all. `offline_access` is added to a non-empty
request when the authorization server lists it, to ask for a refresh
token.

A 403 with `error="insufficient_scope"` steps up: the client asks again
for the scopes it asked for before plus the challenged ones, and retries
the request with the new token. It does not when the token already has
every challenged scope (asking again would end in the same 403), and one
request runs the flow at most twice; past that, the 403 comes back as
`{:error, {:insufficient_scope, challenge}, session}`.

### Step-up on how the person signed in

A tool may need the person to have signed in strongly, or recently (RFC
9470): the server answers 401 with
`error="insufficient_user_authentication"`, and `acr_values` and
`max_age` in the challenge. The client runs the person's grant again,
the code flow or the device flow, with those two as the authorization
request's parameters of the same names (pushed, when the server takes
pushed requests), the scopes asked for before, and any the challenge
names; the authorization server has the person sign in again as asked,
and the request goes again with the new token. It does so once per
request: a sign-in the server still refuses comes back as
`{:error, {:insufficient_user_authentication, challenge}, session}`, the
challenge's `acr_values` and `max_age` saying what it wanted. A DPoP
nonce retry does not count.

A machine grant (client credentials, JWT bearer, enterprise-managed) has
nobody to sign in again: the 401 comes back as
`{:error, {:auth, {:insufficient_user_authentication, challenge}}, session}`
at once. With `static: true`, as for any refusal, it is
`{:error, {:insufficient_user_authentication, challenge}, session}`.

### DPoP

With DPoP (RFC 9449, SEP-1932) the client's tokens are bound to a key it
holds, and a token that leaks is useless without the key. The client
uses it when the authorization server's metadata lists ES256 in
`dpop_signing_alg_values_supported`, and when the optional `jose`
dependency is there:

```elixir
auth: [..., dpop: :auto]    # the default
auth: [..., dpop: true]     # send proofs to any server (raises without jose)
auth: [..., dpop: false]    # bearer tokens only
```

Each authorization makes a new P-256 key. Every token request (the code
exchange, a refresh, the machine grants) carries a proof made with it,
and a token that comes back with `token_type` `DPoP` is bound to it;
a server that binds nothing answers `Bearer`, and the token goes as a
bearer token. Every request to the MCP server — the POSTs, a legacy
session's GET stream and its DELETE — sends a bound token as
`Authorization: DPoP <token>` with a fresh proof for that method and
URL, carrying the token's hash. A refresh keeps the key: the
authorization server may have bound the refresh token to it.

A server that wants a nonce in its proofs answers `use_dpop_nonce` with
a `DPoP-Nonce` header. The client sends the request again at once with
the nonce, and keeps the latest one each server sends for its next
proofs. A nonce retry is not an authorization: it does not count
towards the two a request may run, and nobody is asked anything.

A resource whose metadata says `dpop_bound_access_tokens_required` (RFC
9728) gets DPoP with `:auto` even when its authorization server's
metadata lists no algorithms. A client that cannot use DPoP there
(`dpop: false`, or no `jose`) stops before the flow runs, with
`{:error, {:auth, {:dpop_required, :dpop_off | :no_jose}}}`, rather than
fetching tokens the server would refuse.

The key is kept with the token, as PEM under `"dpop_key"`, in the session
and in the `store:` when there is one.

### Keeping tokens across runs

Tokens and dynamic registrations live in the session by default. To keep
them across runs, pass `store: {module, arg}`, a module implementing
`Sake.Client.Auth.Store` (`fetch/2` and `put/3`, with JSON-friendly maps);
its documentation has a file-based example. The values hold credentials,
a DPoP-bound token's private key, and an identity provider's refresh
token from a SAML exchange (which stands for the person's sign-on until
it expires): store them where only the person running the client can
read them.

### Errors

A failure inside the flow comes back as `{:error, {:auth, reason}}` from
`connect/2` (or `{:error, {:auth, reason}, session}` from a later call).
The reasons name what stopped it: `{:resource_mismatch, resource}`,
`{:issuer_mismatch, expected, got}` (from the metadata or the
authorization response), `:pkce_not_supported`, `:missing_iss`,
`:state_mismatch`, `{:denied, error, description}`,
`{:insecure_url, url}`, `:no_client_registration`,
`{:registration_failed, ...}`, `{:token_failed, ...}`,
`:no_device_endpoint`, `{:device_authorization_failed, ...}`,
`:access_denied` and `:expired_token` (the device grant),
`{:token_exchange_failed, ...}`, `{:saml_exchange_failed, ...}`,
`{:insufficient_user_authentication, challenge}` (a machine grant asked
for a person's sign-in), `{:authorize, reason}` (your `authorize:`
function's error),
`{:assertion, reason}` (your `assertion:`, `id_token:` or
`saml_assertion:` function's), and so on.

### Without `auth:`

A 401 comes back to you as
`{:error, {:unauthorized, %Sake.Auth.Challenge{}}}` (or
`{:error, {:insufficient_user_authentication, %Sake.Auth.Challenge{}}}`
for RFC 9470's challenge, whose `acr_values` and `max_age` say how the
person must sign in), and nothing else happens — no browser opens that nobody asked for:

```elixir
case Sake.Client.connect(url) do
  {:ok, session} -> session
  {:error, {:unauthorized, %Sake.Auth.Challenge{resource_metadata: url, scope: scopes}}} ->
    # url is the protected resource metadata document; scopes is what the
    # server asks for.
    raise "authorization required at #{url} for #{Enum.join(scopes, " ")}"
end
```

`Sake.Auth.Challenge` (formerly `Sake.Client.Challenge`) parses the
`WWW-Authenticate` header (scheme, `resource_metadata`, `scope`,
`error`, `error_description`, `realm`, and the `DPoP-Nonce` header as
`nonce`). A
bearer token you obtained some other way goes in `headers:`.
