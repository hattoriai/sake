# Quickstart

## Add the dependency

```elixir
def deps do
  [
    {:sake, "~> 0.4"},
    {:bandit, "~> 1.5"}
  ]
end
```

`bandit` (or Phoenix's own endpoint) serves the HTTP; Sake is a Plug.

## Start Sake

Add `Sake` to your supervision tree. Without `auth:`, only the stream
registry and tasks run — good enough for a first server:

```elixir
children = [
  {Sake, secret_key_base: MyAppWeb.Endpoint.config(:secret_key_base)},
  MyAppWeb.Endpoint
]
```

`secret_key_base:` can be a binary of at least 32 bytes, or `{m, f, a}`
to read it lazily (from `MyAppWeb.Endpoint.config/1`, for instance). It
signs legacy session IDs and the state of multi round-trip requests
(elicitation, sampling, roots).

## Write a server and a tool

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"

  tools [MyApp.MCP.Echo]
end

defmodule MyApp.MCP.Echo do
  use Sake.Tool, name: "echo", description: "Returns the text it receives"

  arg :text, :string, required: true, description: "The text to return"

  @impl true
  def execute(%{text: text}, _ctx), do: {:ok, text}
end
```

`Sake.Server` builds the tool list, capability negotiation and dispatch;
`Sake.Tool` compiles `arg` lines into a JSON Schema and validates every
call before `execute/2` runs. See `guides/tools.md` for arguments, results,
streaming and elicitation, and `guides/resources_and_prompts.md` for
resources and prompts.

## Mount the endpoint

In a Phoenix router:

```elixir
import Sake.Router

scope "/" do
  forward "/mcp", Sake.Plug, server: MyApp.MCP
end
```

Or with `sake_endpoint`, which also works under a scope with a dynamic
segment (see `guides/tenants.md`):

```elixir
scope "/" do
  sake_endpoint "/mcp", server: MyApp.MCP
end
```

In a bare Plug app, `forward` works the same way:

```elixir
forward "/mcp", to: Sake.Plug, init_opts: [server: MyApp.MCP]
```

The endpoint speaks the modern (2026-07-28) protocol and the three
handshake-era revisions (2025-11-25, 2025-06-18, 2025-03-26) on the same
path — a client picks whichever it supports; see
`guides/protocol_versions.md`.

## Connect a client

```
claude mcp add --transport http my-app https://myapp.example.com/mcp
```

The client sends `tools/list`, then `tools/call` with `{"name": "echo",
"arguments": {"text": "hi"}}`, and gets back `{"content": [{"type":
"text", "text": "hi"}]}`.

## Turn on authorization

An unauthenticated endpoint is fine for an internal tool; anything a
person connects a client to should require a token. Five steps:

1. **A subject module** — how Sake reads and loads the signed-in person:

   ```elixir
   defmodule MyApp.MCP.Subject do
     @behaviour Sake.Auth.Subject

     @impl true
     def from_conn(conn) do
       case Plug.Conn.get_session(conn, :user_id) do
         id when is_binary(id) -> MyApp.Accounts.fetch(id)
         _ -> :error
       end
     end

     @impl true
     def id(user), do: user.id
     @impl true
     def fetch(id), do: MyApp.Accounts.fetch(id)
     @impl true
     def display(user), do: user.email
   end
   ```

2. **A migration**, if you want tokens to survive a restart (the default
   ETS store does not):

   ```elixir
   defmodule MyApp.Repo.Migrations.AddSakeAuth do
     use Ecto.Migration
     def up, do: Sake.Auth.Migration.up()
     def down, do: Sake.Auth.Migration.down()
   end
   ```

3. **Configuration** on the `Sake` child:

   ```elixir
   {Sake,
    secret_key_base: MyAppWeb.Endpoint.config(:secret_key_base),
    auth: [
      subject: MyApp.MCP.Subject,
      issuer: "https://myapp.example.com",
      servers: [MyApp.MCP],
      store: {Sake.Auth.Store.Ecto, repo: MyApp.Repo}
    ]}
   ```

4. **The router macros** — discovery, the token/register/revoke API, and
   the authorize page behind your existing login pipeline:

   ```elixir
   scope "/" do
     sake_well_known()
   end

   scope "/oauth" do
     pipe_through :api
     sake_oauth_api()
   end

   scope "/oauth" do
     pipe_through [:browser, :require_authenticated_user]
     sake_oauth_authorize()
   end
   ```

5. **`auth: true`** on the endpoint:

   ```elixir
   sake_endpoint "/mcp", server: MyApp.MCP, auth: true
   ```

That is a full OAuth 2.1 authorization server: PKCE, dynamic client
registration, Client ID Metadata Documents, a consent page, and token
rotation. See `guides/authorization.md` for the flow end to end.

## Try it locally

This repository's `dev/` directory is a small but complete app: `mix dev`
starts it on `http://localhost:4000`, with a login form, the OAuth
endpoints, and a few example tools, resources and prompts. Read
`dev/lib/sake_dev/router.ex` and `dev.exs` alongside this guide — they are
the shortest path from zero to a signed-in `tools/call`.
