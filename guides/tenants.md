# Multi-tenant endpoints

A SaaS app usually wants one MCP endpoint per organization, not one
endpoint shared by everyone. Sake does this with one path per tenant
(each its own OAuth resource) rather than a single path that branches on
a request parameter — a bearer token is scoped to the exact resource URL
it was issued for, so a token minted for one tenant's endpoint simply does
not work against another's.

## One endpoint per tenant path

```elixir
scope "/:org_slug" do
  sake_endpoint "/mcp", server: MyApp.MCP, auth: true
end
```

`sake_endpoint` compiles to `Phoenix.Router.match(:*, ...)`, which — unlike
`forward` — accepts a dynamic segment in its scope. A Plug-only host
cannot express a dynamic segment this way (`Plug.Router`'s `forward` takes
a literal prefix); mount one `forward` per known tenant instead, as the
development router in `dev/lib/sake_dev/router.ex` does for `/acme/mcp`
and `/beta/mcp`.

## The canonical resource

The token audience Sake checks on every request is the endpoint's own
canonical URL: origin plus request path, e.g.
`https://app.example.com/acme/mcp`. A token minted for `.../acme/mcp`
gets a 401 against `.../beta/mcp` even with an otherwise-valid signature
and an unexpired lifetime — the bearer check compares
the stored token's resource against the endpoint's own canonical URL for the exact
conn it is serving.

## `resources:` patterns

The authorization server needs to know which resource URLs it is allowed
to issue tokens for; list them (relative to the issuer) with `:`-prefixed
segments as tenant placeholders:

```elixir
auth: [
  ...,
  resources: ["/mcp", "/:org_slug/mcp"]
]
```

An authorize request's `resource` parameter (RFC 8707) must match one of
these patterns (segment-for-segment, a `:`-prefixed pattern segment
matching anything) or the request is rejected with `invalid_target`. The
`resource` parameter is required on every authorize request *unless*
`resources:` names exactly one pattern with no placeholder at all — a
single-tenant server can omit it, since there is only one resource it
could mean. At the token endpoint `resource` is optional: the code or
refresh token already carries it, and a `resource` that is given must
match it.

## Tokens per tenant

Because the resource is part of the token record, a client that talks to
two tenants (an integration platform connecting several of your
customers, say) needs a separate authorization for each: separate tokens
and a separate consent, since a remembered consent is kept per person,
client and resource.
`Sake.Auth.list_grants/2` and `revoke_grant/3` (see
`guides/authorization.md`) work the same way per subject regardless of how
many tenant resources that subject holds tokens for — each shows up as
its own row.

## Who may authorize which tenant

Two checks keep tenants apart, and a multi-tenant host needs both:

- **The audience check** (above) stops token *reuse* across tenants: a
  token issued for `/acme/mcp` never works against `/beta/mcp`.
- **`authorize_resource?/2`** stops Sake from *issuing* a token for a
  tenant the person does not belong to. Without it, any signed-in person
  could authorize a client for any organization's endpoint.

The authorize request happens at `/oauth/authorize`, outside any tenant
path, so the tenant is not in `conn.params` there: it is in the resource
URL the client asked for. `authorize_resource?/2` receives the signed-in
person and that URL; return `false` and the client gets `access_denied`
("You may not authorize this resource"):

```elixir
defmodule MyApp.MCP.Subject do
  @behaviour Sake.Auth.Subject

  @impl true
  def from_conn(conn) do
    case conn.assigns[:current_scope] do
      %{user: user} -> {:ok, user}
      _ -> :error
    end
  end

  @impl true
  def id(user), do: user.id
  @impl true
  def fetch(id), do: MyApp.Accounts.fetch_user(id)
  @impl true
  def display(user), do: user.email

  # "https://app.example.com/acme/mcp" -> "acme"
  @impl true
  def authorize_resource?(user, resource) do
    case URI.parse(resource).path |> String.split("/", trim: true) do
      [org_slug, "mcp"] -> MyApp.Accounts.member?(user, org_slug)
      _ -> false
    end
  end
end
```

## The principal a tool sees

The `Sake.Auth.Subject` behaviour's `fetch/1` returns whatever principal
your app already uses; nothing about tenancy is baked into it. On every
MCP request the tenant is in the request path, so the place to attach the
organization is `scope:` (the `Sake.Plug` option, not an OAuth scope),
which turns the conn into what a tool sees as `ctx.scope`. The default is
`conn.assigns[:sake_scope]`, set from the bearer token's principal;
return the organization alongside the person there (the conn's
`path_params` carry the org slug), and every tool knows which tenant it
is serving without re-deriving it itself.
