# Shipping a server in a library

A library that runs inside its host's app can ship its own MCP server: a
reporting engine exposes its saved reports and queries, a CMS its pages,
a job queue its queues. The host decides whether and where to serve it,
and who may use it. This guide is for the library's author; the host
writes nothing but a router line, or a `mount`, and its subject module.

## Sake as an optional dependency

Most of the library's users will not want MCP, so make Sake optional:

```elixir
# the library's mix.exs
{:sake, "~> 0.4", optional: true}
```

and compile the MCP modules only when the host has Sake:

```elixir
if Code.ensure_loaded?(Sake.Server) do
  defmodule Reports.MCP do
    @moduledoc "The Reports MCP server. See the Reports MCP guide."
    use Sake.Server,
      name: "reports",
      version: "1.4.0",
      instructions: "Use list_reports to find a report, then run_report to run it."

    scope "reports:read", "Read and run saved reports"
    scope "reports:write", "Create and change saved reports"

    tools [Reports.MCP.ListReports, Reports.MCP.RunReport, Reports.MCP.SaveReport]
    resources [Reports.MCP.Report]
  end
end
```

Wrap each tool, resource and prompt module the same way. A host that
adds `{:sake, "~> 0.4"}` to its own deps gets them; Mix compiles an
optional dependency the host has before the library that names it.
`version:` may be a module attribute (`@version` set from the library's
version) as well as a literal.

## Configuration at runtime

The server compiles inside the library, before the host's application
starts, so read the host's configuration where the tools run, not when
they compile:

```elixir
def execute(%{id: id}, ctx) do
  limit = Application.get_env(:reports, :mcp, [])[:max_rows] || 500
  ...
end
```

What the server lists is fixed when it compiles. A host that wants less
of it mounts it with `only:` or `except:` (below); a list that depends on
the principal or on configuration belongs in an `:after_list`
middleware, which filters both the list and the calls
(`guides/middleware.md`).

## The principal

`ctx.scope` is the host's principal: whatever its `Sake.Auth.Subject`
module's `fetch/1` returns, or the `scope:` function of an endpoint
without authorization. The library does not know its shape, so do not
pattern-match on it. Either pass it through as an opaque value to the
library's own API, the way the library already takes the current user
from its other front ends, or let the host map it:

```elixir
# the host's config
config :reports, :mcp, actor: {MyApp.Reporting, :actor_for}

# in the library
defp actor(ctx) do
  case Application.get_env(:reports, :mcp, [])[:actor] do
    {m, f} -> apply(m, f, [ctx.scope])
    nil -> ctx.scope
  end
end
```

The library's own access rules (visibility, row limits, read-only
connections) apply as for any other caller: MCP is one more front end,
not a way around them.

## Scopes and annotations

Declare the scopes the library's tools require with `scope`, under the
library's own prefix (`reports:read`, not `read`), and document them:
the host's `scopes_for/2` maps its roles to them (`guides/authorization.md`),
and the consent page shows their descriptions. Split them by what a
host would give different people: reading, running, changing.

Mark each tool with what it does, since clients use the hints to decide
what to ask the person before calling:

```elixir
use Sake.Tool,
  name: "run_report",
  scope: "reports:read",
  annotations: [read_only: true, idempotent: true, open_world: false]

use Sake.Tool,
  name: "delete_report",
  scope: "reports:write",
  annotations: [destructive: true]
```

The hints are not enforced; the scopes are. A tool that writes needs a
write scope whatever its annotations say.

## How the host serves it

On an endpoint of its own:

```elixir
# the host's router
sake_endpoint "/reports/mcp", server: Reports.MCP, auth: true

# the host's Sake child
{Sake, secret_key_base: ..., auth: [subject: MyApp.MCP.Subject, servers: [Reports.MCP], ...]}
```

Or mounted in the host's own server, alongside its tools, with a prefix
so names cannot clash, and only the parts it wants:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  tools [MyApp.MCP.Search]
  mount Reports.MCP, prefix: "reports", except: [Reports.MCP.DeleteReport]
end
```

A mounted server's middleware runs around its own components, but its
`:before_request` does not run: put what must run on every request in
the tools, or in the plugs of the component events (`guides/composing.md`).

## Names are the library's API

Tool names, argument names, resource URIs and scope names reach the
host's users: in their clients' permission lists (Claude Code's
`mcp__<server>__run_report`), in prompts and skills they wrote, in the
host's `only:` and `except:`, and in its `scopes_for/2`. Renaming one is
a breaking change, to note in the changelog as one. Add arguments as
optional; add tools rather than changing what one does.

## Testing

Test the server as the host would run it, with a principal of the shape
the library takes and the scopes a role would hold:

```elixir
import Sake.Test

client = connect(Reports.MCP, scope: %{user_id: 1}, scopes: ["reports:read"])
assert {:ok, %{structured: %{"rows" => _}}} = call_tool(client, "run_report", %{"id" => 7})
assert {:error, {:insufficient_scope, _}} = call_tool(client, "save_report", %{"name" => "x"})
```

See `guides/testing.md`. The library's own test suite has Sake without
anything more: Mix fetches a project's optional dependencies for the
project itself.
