# Bring your own authorization server

`Sake.Auth` makes your app the authorization server for its MCP endpoint.
Many apps already have one: an OAuth provider inside the app
(ExOauth2Provider, Boruta, a hand-rolled one) or an identity provider
outside it (Keycloak, Auth0, Okta, Entra ID, Cognito, WorkOS). Such an app
plugs Sake in as a resource server only: its authorization server issues
the tokens, and Sake checks them and enforces the scopes, without running
a second authorization server next to the first.

## Configuration

Name each authorization server in the `Sake` child, and point an endpoint
at it by name:

```elixir
# In your supervision tree:
{Sake,
 secret_key_base: MyAppWeb.Endpoint.config(:secret_key_base),
 external_auth: [
   keycloak: [
     issuer: "https://sso.example.com/realms/acme",
     verify: :jwt,
     servers: [MyApp.MCP]
   ]
 ]}
```

```elixir
# In your Phoenix router:
import Sake.Router

scope "/" do
  sake_well_known()
  sake_endpoint "/mcp", server: MyApp.MCP, auth: :keycloak
end
```

`auth: true` still means `Sake.Auth`; `auth: :keycloak` means the
`keycloak` configuration. Sake's own authorization server is not needed
at all: leave out `auth:` in the child, and the OAuth routes
(`sake_oauth_api`, `sake_oauth_authorize`) in the router. Only the
well-known routes stay, for the endpoint's protected resource metadata.

Both can run side by side, one endpoint on Sake's own tokens and another
on an identity provider's. Each configuration then says which endpoint
paths it protects (`resources:`, with `:param` segments, as for
`Sake.Auth`), so that the metadata at each path names the right
authorization server:

```elixir
{Sake,
 auth: [subject: MyAppWeb.MCPSubject, issuer: "https://myapp.example.com", servers: [MyApp.MCP]],
 external_auth: [
   okta: [
     issuer: "https://acme.okta.com/oauth2/default",
     verify: :jwt,
     servers: [MyApp.PartnerMCP],
     resources: ["/partners/mcp"]
   ]
 ]}
```

Sake refuses to start when it knows more than one authorization server
and a configuration has no `resources:`. Every option is in
`Sake.Auth.External`.

## What an MCP client sees

The same as with `Sake.Auth`. A request without a token gets a 401 whose
`WWW-Authenticate` names the endpoint's protected resource metadata
(RFC 9728), at the same path-suffixed URL
(`/.well-known/oauth-protected-resource/mcp`). The document lists your
authorization server's issuer in `authorization_servers`, the scopes your
servers declare in `scopes_supported`, and the DPoP algorithms when DPoP
is on. The client then reads your authorization server's own metadata
(RFC 8414 or OpenID Connect discovery), gets a token there, and comes
back with it. A tool the token's scopes do not cover gets a 403 with an
`insufficient_scope` challenge that points at the same metadata, so the
client steps up at your authorization server as it would at Sake's.

`/.well-known/oauth-authorization-server` is `Sake.Auth`'s; without it,
that path answers 404, and your authorization server serves its own
metadata.

## Verifying the tokens

### JWT access tokens (Keycloak, Auth0, Okta, Entra ID, Cognito, WorkOS)

`verify: :jwt` checks a JWT access token (RFC 9068) with the issuer's
public keys: the signature (RS256, PS256, ES256 or ES384 only; `none`
and the HMAC algorithms are refused, so a token "signed" with the public
key as an HMAC secret gets nowhere), `iss` (exactly the configured
issuer), `aud`, `exp`, `nbf` and `iat` (30 seconds of clock skew), and
the `typ` header. It needs the optional `jose` dependency; without it
Sake refuses to start.

The keys come from `jwks:` (a JWK Set), `jwks_uri:`, or else the
`jwks_uri` of the issuer's OpenID Connect or RFC 8414 metadata. They are
cached for the document's `max-age`; a token signed with a key ID the
cached set does not have fetches the set again, at most once a minute,
so a key the issuer rotates in is picked up and nobody can make the
server fetch on every request by inventing key IDs.

RFC 9068 types access tokens `at+jwt`, which is the default `typ:`. Many
identity providers type them plain `JWT`; say so (`typ: "JWT"`), or
`typ: :any`. The `typ` keeps an ID token, or any other JWT the issuer
signs, from passing for an access token; with `typ: "JWT"` the audience
check is what stops an ID token (whose `aud` is a client, not your
endpoint), so keep it.

Keycloak, with an audience mapper on the client scope that adds the
endpoint's URL to `aud`:

```elixir
keycloak: [
  issuer: "https://sso.example.com/realms/acme",
  verify: :jwt,
  typ: "JWT",
  servers: [MyApp.MCP],
  principal: &MyApp.Accounts.fetch_by_keycloak_claims/1
]
```

Auth0, with an API whose identifier is the endpoint's URL (Auth0's
issuer ends with a slash, and must be given exactly so):

```elixir
auth0: [
  issuer: "https://acme.us.auth0.com/",
  verify: :jwt,
  typ: "JWT",          # "at+jwt" with the API's RFC 9068 token profile
  servers: [MyApp.MCP]
]
```

When the API identifier is not the endpoint's URL, list it in
`audiences:` (see the audience note below).

### Token introspection (RFC 7662)

For opaque tokens, or to see a revocation sooner, Sake can ask the
authorization server's introspection endpoint about each token,
authenticated as the resource with credentials that server gave it:

```elixir
okta: [
  issuer: "https://acme.okta.com/oauth2/default",
  verify:
    {:introspection,
     endpoint: "https://acme.okta.com/oauth2/default/v1/introspect",
     client_id: "mcp-resource",
     client_secret: System.fetch_env!("OKTA_RESOURCE_SECRET"),
     auth_method: :basic,      # or :post
     cache: 60},
  servers: [MyApp.MCP]
]
```

A token is taken when the answer says `active: true`, its `exp` and
`nbf` (when there) hold, its `iss` (when there) is the issuer, and its
`aud` passes the audience check. An active answer is cached, keyed by a
SHA-256 digest of the token (the token itself is never kept), for
`cache:` seconds and never past the token's `exp`. An inactive answer is
not cached.

### Your own code (ExOauth2Provider, Boruta, a hand-rolled provider)

A provider inside your app needs no network at all: one query finds the
token. Give `verify:` a module that implements
`c:Sake.Auth.External.verify_token/2` (or a function of the token and
the conn). It returns the token's claims in the shape of an
introspection answer, with string or atom keys: `sub`, `client_id`,
`scope` (a string or a list), `exp` (seconds or a `DateTime`), `aud`, and
`cnf: %{jkt: ...}` for a DPoP-bound token. `{:ok, claims, principal}`
hands over the principal too, when the query loaded it, so no second
query is made; `:error` refuses the token.

ExOauth2Provider (whose `authenticate_token/2` checks expiry and
revocation and preloads the resource owner):

```elixir
defmodule MyApp.MCPTokens do
  @behaviour Sake.Auth.External

  @impl true
  def verify_token(token, _conn) do
    case ExOauth2Provider.authenticate_token(token, otp_app: :my_app) do
      {:ok, access_token} ->
        {:ok,
         %{
           sub: access_token.resource_owner_id && to_string(access_token.resource_owner_id),
           client_id: to_string(access_token.application_id),
           scope: access_token.scopes
         }, access_token.resource_owner}

      {:error, _reason} ->
        :error
    end
  end
end
```

Boruta:

```elixir
def verify_token(token, _conn) do
  case Boruta.Oauth.Authorization.AccessToken.authorize(value: token) do
    {:ok, %Boruta.Oauth.Token{} = t} ->
      {:ok, %{sub: t.sub, client_id: t.client.id, scope: t.scope, exp: t.expires_at}}

    {:error, _error} ->
      :error
  end
end
```

```elixir
in_app: [
  issuer: "https://myapp.example.com",
  verify: MyApp.MCPTokens,
  audiences: :any,     # the provider's tokens are good for the whole app
  servers: [MyApp.MCP]
]
```

Check those calls against the version of the library you run; they are
the libraries' own API, not Sake's. Neither knows RFC 8707's resource
parameter, so their tokens carry no audience, hence `audiences: :any`
above (read the note below first). MCP clients find your provider
through its metadata at the issuer (RFC 8414,
`/.well-known/oauth-authorization-server`): serve that document if the
library does not.

## The token, the principal and the scopes

Whichever way it was verified, a token becomes the
`Sake.Auth.TokenRecord` a token of `Sake.Auth` becomes, in `ctx.token`:
`scopes` from `scope` (or `scp`, a string or a list), `client_id` from
`client_id` (or `azp`), `subject_id` from `sub`, `jkt` from `cnf.jkt`,
`expires_at` from `exp`, plus `issuer` and the verified `claims`. A
token without `sub`, or whose `sub` is its own client (RFC 9068 §2.2, the
client credentials grant), is a machine client's: `subject_id` is `nil`.

A token can be bound to its client only in a way Sake checks: DPoP's
`cnf.jkt` (below). A token whose `cnf` names any other binding, such as
a client certificate (`cnf.x5t#S256`, RFC 8705), is refused like any
invalid token (a 401), whether it comes as a bearer token or with a DPoP
proof: taken without the check, the binding would protect nothing. If
your authorization server binds tokens to certificates, have it issue
unbound or DPoP-bound tokens for this resource.

`ctx.scope`, the principal your tools see, is what `principal:` returns
for the claims (`{:ok, principal}`, or `:error` to refuse the token), the
callback's own principal, or by default the claims map itself:

```elixir
principal: fn claims -> MyApp.Accounts.fetch_by_external_id(claims["iss"], claims["sub"]) end
```

Everything downstream is unchanged: `scope:` on components and the
step-up challenges, middleware, `ctx.token` in tools, and the ownership
of tasks. Tasks and the signed request states of multi round-trip
requests are bound to the issuer as well as the subject: the same `sub`
from another issuer, or from `Sake.Auth`, is someone else.

## The audience

A token issued for one resource must not be accepted by another: a
token your identity provider issued for some other API, or for an
attacker's MCP server that the same person signed in to, would
otherwise work here too. So a token must carry an audience Sake accepts:
by default the endpoint's own URL, which an authorization server that
supports RFC 8707 puts in `aud` when the client asks for that resource,
as MCP clients do.

When your authorization server ignores the `resource` parameter, give it
an audience it does put in its tokens for this endpoint (an API
identifier, a client ID) with `audiences: [...]`; Sake then accepts those
instead of the URL. Make it one that names this endpoint alone.

`audiences: :any` turns the check off, and Sake never does that on its
own. Use it only when every token the authorization server issues is
meant for this app anyway, as with a provider inside the app that serves
nothing else, and never for a shared identity provider.

## DPoP

A token the authorization server bound to the client's key (`cnf.jkt`
in the JWT, the introspection answer, or the callback's claims) is taken
only with `Authorization: DPoP` and a proof of that key for the request,
exactly as a bound token of `Sake.Auth` (see the authorization guide):
sent as a bearer token, with a proof of another key, for another URL, or
a replayed proof, it is refused. `dpop:` takes the same values as for
`Sake.Auth`: `dpop: [nonce: true]` makes the endpoint require its own
nonces (they are the resource's, made with the Sake secret, which `Sake`
reads once when it starts, independent of the authorization server's), and `dpop: [required: true]` refuses
unbound tokens and says `dpop_bound_access_tokens_required` in the
metadata. Whether your authorization server binds tokens at all is its
own setting (Keycloak and Okta, among others, can).

## Revocation and caching

A JWT access token is checked locally: a token the authorization server
revokes works here until it expires. Keep access token lifetimes short
at your authorization server when that matters. Introspection sees a
revocation at the next request that is not answered from the cache, so
within `cache:` seconds (default 60); `cache: 0` asks on every request,
at the cost of a round trip each time. Your own callback is asked on
every request, and sees what your database sees.

## Client registration

Most external authorization servers offer neither dynamic client
registration nor Client ID Metadata Documents, which MCP clients use to
register themselves. Their clients then need a client ID registered
there in advance, which most MCP clients take in their configuration:
`Sake.Client` takes `client_id:` (and `client_secret:` or
`private_key:`) for `grant: :authorization_code` or
`grant: :client_credentials`. Register the redirect URIs the client
uses, and the scopes your servers declare.

## The authorization extensions in the capabilities

An endpoint on `Sake.Auth` declares the authorization extensions whose
grants Sake's authorization server offers. An external authorization
server's grants are its own business: by default its endpoints declare
none, and `extensions: [:client_credentials, :enterprise]` declares the
ones it does offer (`io.modelcontextprotocol/oauth-client-credentials`,
`io.modelcontextprotocol/enterprise-managed-authorization`, the
identifiers of `Sake.Protocol.auth_extension/1`).

## Testing

`Sake.Test.connect/2` without `plug:` needs nothing: its `scopes:` token
stands for any authorization server's. Through a plug, `scopes:` issues
a `Sake.Auth` token, which an external-auth endpoint does not take; send
one it accepts in `headers:` instead, such as a token your test
configuration's `verify:` callback knows.

## Finding out why a token is refused

Every refusal is the telemetry event `[:sake, :auth, :external,
:refused]`, with the configuration's `name`, its `issuer` and the
`reason`: `:invalid_audience`, `:invalid_issuer`, `:expired`,
`:not_yet_valid`, `:bad_signature`, `:no_key`, `:unsupported_alg`,
`:invalid_typ`, `:inactive`, `:unreachable`, `:no_principal`,
`:unsupported_confirmation`, and the like. The client only sees the 401.
