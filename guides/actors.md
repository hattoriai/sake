# Acting as someone

A person signs in to your server once, with OAuth, and their token is
theirs. But they often work through several identities: agents with their
own names, instructions and memory, or, for an admin, the organization's
bot. With `actors`, the model acts as any of them, and switches between
them in one connection, call by call. There is no server entry per
identity in the client, and no session that remembers a choice.

## Declaring the actors

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  tools [MyApp.MCP.EditPage, MyApp.MCP.ListPages]
  actors MyApp.MCP.Actors
end

defmodule MyApp.MCP.Actors do
  @behaviour Sake.Actors
  alias Sake.Actors.Actor

  # Who this person may act as: their agents, and the bot for an admin.
  @impl true
  def list(ctx) do
    agents =
      for agent <- MyApp.Agents.of(ctx.scope.user) do
        %Actor{
          id: "agent:#{agent.id}",
          name: agent.name,
          description: agent.summary,
          instructions: agent.persona,
          data: agent
        }
      end

    if ctx.scope.admin?,
      do: agents ++ [%Actor{id: "bot", name: "The team's bot", data: :bot}],
      else: agents
  end

  # A call without `as`: the person themselves.
  @impl true
  def default(_ctx), do: nil
end
```

`list/1` is the only callback you must write. `fetch/2` looks one actor
up by its id (by default, Sake finds it in `list/1`), and `default/1` is
the actor of a call without `as` (`nil` by default: the principal).

## What the model gets

- **`list_actors`**: the identities it may act as, and the default.
- **`act_as`**: takes an `id` and returns the actor's name and
  `instructions`. The model takes on that persona.
- **`as`**: an optional argument on every other tool. The model passes the
  actor's id while it acts as it.

So "act as Bo" becomes a call to `act_as` and then `"as": "agent:2"` on the
next calls. Another conversation on the same connection can act as Ada at
the same time.

## What your tools get

Sake takes `as` out of the arguments before they are validated, so a
tool's schema never declares it. It asks `fetch/2` for the actor, then
sets `ctx.actor`:

```elixir
def execute(%{page_id: id, text: text}, ctx) do
  author = if ctx.actor, do: ctx.actor.data, else: ctx.scope.user
  MyApp.Pages.edit(ctx.scope, id, text, by: author)
end
```

Middleware sees `ctx.actor` too, from `:before_call` on, so one plug can
audit or limit every call by its actor.

## Trust

Nothing the model sends is trusted. Every `as` is checked against the
principal (`ctx.scope`) on every call: an id the person may not act as
is a tool error, which tells the model to call `list_actors`. The model
can act only as someone its person may act as, and the token stays the
person's. Keep `list/1` and `fetch/2` cheap, as they run on calls.

What an actor may do is your app's decision. The principal stays the
token's subject; the actor acts for them, as in the `act` claim of OAuth
Token Exchange (RFC 8693). For example, a page closed to agents can
refuse a call with an agent actor, though the person may edit it.

## Why each call carries it

From `2026-07-28`, MCP is stateless: no session holds a choice between
two requests, and the specification advises that state across calls
travel as arguments the model passes back. `as` is such an argument.
When clients can pick an identity themselves and send it in the token,
only where your app reads the actor changes: `ctx.actor` stays.

## Limits

- A tool that declares its own argument named `as` keeps it. Sake does
  not add or take it, and its calls act as the default.
- The actors are the server's that serves the request. They apply to the
  tools of the servers it mounts and of the upstreams it proxies. An
  upstream never sees `as`.
- Resources and prompts are read as the principal.
