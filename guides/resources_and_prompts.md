# Resources and prompts

## Fixed resources

```elixir
defmodule MyApp.MCP.Readme do
  use Sake.Resource,
    uri: "dev://readme",
    name: "readme",
    title: "About this server",
    mime_type: "text/markdown"

  @impl true
  def read(%{}, _ctx), do: {:ok, "# my-app\n\nAn example MCP server."}
end
```

`read/2` returns `{:ok, text}`, `{:ok, {:blob, binary, mime_type}}` for
binary content, `{:ok, map_or_list}` (JSON-encoded, `mime_type` defaults to
`"application/json"`), `{:ok, [%Sake.Content{}, ...]}` for full control, or
`{:error, :not_found}` / `{:error, text}`.

## Template resources

A `{name}` placeholder in `uri:` makes a resource a template; `read/2`
receives the matched segments as atom-keyed params:

```elixir
defmodule MyApp.MCP.Issue do
  use Sake.Resource,
    uri: "issue://{id}",
    name: "issue",
    mime_type: "application/json",
    scope: "issues:read",
    subscribe: true

  @impl true
  def read(%{id: id}, _ctx) do
    case Issues.fetch(id) do
      {:ok, issue} -> {:ok, issue}
      :error -> {:error, :not_found}
    end
  end
end
```

## `list/1`

A template resource can implement `list/1` to enumerate the concrete
resources `resources/list` should advertise (a fixed resource is always
listed on its own and needs no `list/1`):

```elixir
@impl true
def list(_ctx), do: Enum.map(Issues.all(), &%{uri: "issue://#{&1.id}", name: &1.title})
```

Each entry is a URI string or a map with `:uri` and optional `:name`,
`:title`, `:description`, `:mime_type` overrides for that one item.

## Subscriptions

`subscribe: true` lets a client `resources/subscribe` to a concrete URI
(legacy) or open the modern `subscriptions/listen` stream; announce a
change from anywhere in your app with:

```elixir
Sake.Server.resource_updated(MyApp.MCP, "issue://42")
```

Sake fans that out to every session subscribed to that URI (or to the
open modern stream, filtered to what it asked for) through the stream
registry started by `{Sake, ...}` — no extra wiring needed once the
resource declares `subscribe: true` and a client has subscribed.

## Completion

```elixir
@impl true
def complete("id", partial, _ctx),
  do: {:ok, Issues.all() |> Enum.map(& &1.id) |> Enum.filter(&String.starts_with?(&1, partial))}
```

`complete/3` (optional) answers `completion/complete` for one of the
resource's template parameters, returning `{:ok, values}` or `{:ok,
values, total: n, has_more: true}`. Without it (or for an argument that
returns no matches), the completion endpoint still answers correctly —
just with an empty list; the capability only needs to be declared.

## Prompts

```elixir
defmodule MyApp.MCP.Triage do
  use Sake.Prompt,
    name: "triage",
    title: "Triage an issue",
    description: "Asks for a triage of one issue"

  arg :id, :string, required: true, description: "The issue id"
  arg :tone, :string, description: "kind or direct"

  @impl true
  def get(%{id: id, tone: tone}, _ctx) do
    {:ok, [user: "Triage issue #{id} in a #{tone || "kind"} tone."],
     description: "Triage of issue #{id}"}
  end

  @impl true
  def complete("tone", partial, _ctx),
    do: {:ok, Enum.filter(["kind", "direct"], &String.starts_with?(&1, partial))}

  def complete(_, _, _), do: {:ok, []}
end
```

Prompt `arg` lines take only `:string` (prompt arguments are always
strings on the wire) and the same `required`/`description` options.
`get/2` returns `{:ok, messages}` or `{:ok, messages, description: "..."}`
(falling back to the prompt's own `description`); a message is `{role,
text}` or `{role, %Sake.Content{}}` — `role` is `:user` or `:assistant`.
An embedded resource or image in a message uses the same
`Sake.Content.resource/3` / `image/3` builders as a tool result:

```elixir
{:ok,
 [
   user: Sake.Content.resource("issue://42", issue_json, mime_type: "application/json"),
   user: "Please triage the issue above."
 ]}
```

List resources and prompts on a server the same way as tools:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"
  resources [MyApp.MCP.Readme, MyApp.MCP.Issue]
  prompts [MyApp.MCP.Triage]
end
```
