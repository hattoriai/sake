# The client

`Sake.Client` talks to any MCP server (Sake-built or not) over Streamable
HTTP, on either protocol era.

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
`update_task/3`, `cancel_task/2`, `list_resources/1`,
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

## The 401 challenge, and what to do with it today

```elixir
case Sake.Client.connect(url) do
  {:ok, session} -> session
  {:error, {:unauthorized, %Sake.Client.Challenge{resource_metadata: url, scope: scopes}}} ->
    # url is the oauth-protected-resource metadata document to fetch next;
    # scopes is what the server is asking for. Sake 0.1 stops here.
    raise "authorize at #{url} for #{Enum.join(scopes, " ")}, then retry with a bearer header"
end
```

`Sake.Client.Challenge` parses the `WWW-Authenticate` header (scheme,
`resource_metadata`, `scope`, `error`, `error_description`, `realm`) so
your own code can drive the rest of RFC 9728/8414 discovery and the
authorization code flow yourself — dynamic client registration, opening a
browser for consent, and the token exchange. Sake 0.1's client does not do
any of this itself yet (see the README's status line); pass a bearer
token you obtained some other way through `headers:` on `connect/2` in the
meantime.
