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
(`server/discover`) first; a server that does not speak it responds with
either a recognizable modern JSON-RPC error (reported as-is) or something
else entirely, which is treated as "this must be a legacy server" and
retried with the legacy `initialize` handshake. Force one era directly
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
