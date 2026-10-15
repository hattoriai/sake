# The client

`Sake.Client` talks to any MCP server (Sake-built or not) over Streamable
HTTP, on either protocol era, and runs the MCP authorization flow itself
when a server asks for it (see "Authorization" below).

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

`list_tools/1`, `call_tool/3`, `list_resources/1`,
`list_resource_templates/1`, `read_resource/2`, `list_prompts/1`,
`get_prompt/3`, `complete/4` (`{:prompt, name}` or `{:resource, uri}`, an
argument name, and the partial value), `ping/1`, `discover/1` (the modern
handshake call directly, if you need it), and `close/1` (sends a `DELETE`
on a legacy session; a no-op on modern, which has none to close).

`call_tool/3` returns a `Sake.Client.ToolResult`: `content` (a list of
`Sake.Content.t()`), `structured` (the tool's `structuredContent`, if any),
`is_error` (the tool itself failed — still a successful RPC), `text` (every
text content block joined), and `meta` (the result's `_meta`).

## Era probing

`connect/2` with no `era:` option tries the modern handshake
(`server/discover`) first. An error only a modern server sends (`-32020`,
`-32021`, `-32022`) is reported as-is. "Method not found" (`-32601`) or
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
   for a token, and sends the original request again with
   `Authorization: Bearer`.

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

### Keeping tokens across runs

Tokens and dynamic registrations live in the session by default. To keep
them across runs, pass `store: {module, arg}`, a module implementing
`Sake.Client.Auth.Store` (`fetch/2` and `put/3`, with JSON-friendly maps);
its documentation has a file-based example. The values hold credentials:
store them where only the person running the client can read them.

### Errors

A failure inside the flow comes back as `{:error, {:auth, reason}}` from
`connect/2` (or `{:error, {:auth, reason}, session}` from a later call).
The reasons name what stopped it: `{:resource_mismatch, resource}`,
`{:issuer_mismatch, expected, got}` (from the metadata or the
authorization response), `:pkce_not_supported`, `:missing_iss`,
`:state_mismatch`, `{:denied, error, description}`,
`{:insecure_url, url}`, `:no_client_registration`,
`{:registration_failed, ...}`, `{:token_failed, ...}`,
`{:authorize, reason}` (your `authorize:` function's error), and so on.

### Without `auth:`

A 401 comes back to you as
`{:error, {:unauthorized, %Sake.Client.Challenge{}}}`, and nothing else
happens — no browser opens that nobody asked for:

```elixir
case Sake.Client.connect(url) do
  {:ok, session} -> session
  {:error, {:unauthorized, %Sake.Client.Challenge{resource_metadata: url, scope: scopes}}} ->
    # url is the protected resource metadata document; scopes is what the
    # server asks for.
    raise "authorization required at #{url} for #{Enum.join(scopes, " ")}"
end
```

`Sake.Client.Challenge` parses the `WWW-Authenticate` header (scheme,
`resource_metadata`, `scope`, `error`, `error_description`, `realm`). A
bearer token you obtained some other way goes in `headers:`.
