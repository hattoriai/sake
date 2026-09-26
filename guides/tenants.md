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
`resource` parameter is required on every authorize and token request
*unless* `resources:` names exactly one pattern with no placeholder at
all — a single-tenant server can omit it, since there is only one
resource it could mean.

## Tokens per tenant

Because the resource is part of what gets signed into the token record,
a client that talks to two tenants (an integration platform connecting
several of your customers, say) needs a separate authorization for each:
separate tokens, separate consent, separate revocation.
`Sake.Auth.list_grants/2` and `revoke_grant/3` (see
`guides/authorization.md`) work the same way per subject regardless of how
many tenant resources that subject holds tokens for — each shows up as
its own row.

## The subject module and the organization

The `Sake.Auth.Subject` behaviour's `fetch/1` (and `from_conn/1`) returns whatever principal
your app already uses; nothing about tenancy is baked into the behaviour
itself; it lives in what your principal carries and what `scope:` (the
`Sake.Plug` option, not an OAuth scope) turns it into for a tool:

```elixir
defmodule MyApp.MCP.Subject do
  @behaviour Sake.Auth.Subject

  @impl true
  def from_conn(conn) do
    with id when is_binary(id) <- Plug.Conn.get_session(conn, :user_id),
         {:ok, member} <- MyApp.Accounts.member_of(id, conn.params["org_slug"]) do
      {:ok, member}
    else
      _ -> :error
    end
  end

  @impl true
  def id(member), do: member.user_id
  @impl true
  def fetch(id), do: MyApp.Accounts.fetch_user(id)
  @impl true
  def display(member), do: "#{member.name} @ #{member.org.name}"
end
```

A tool's `ctx.scope` is whatever `Sake.Plug`'s `scope:` function returns
for the conn (default: `conn.assigns[:sake_scope]`, set from the bearer
token's principal) — return the organization alongside the person there,
and every tool sees which tenant it is serving without needing to
re-derive it from the request path itself.
