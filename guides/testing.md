# Testing

`Sake.Test` is a client for your server's tests: the MCP counterpart of
`Phoenix.ConnTest`. It connects to a `Sake.Server` module in memory and
calls it as a real client would, so a test reads like production client
code and exercises everything but the transport.

```elixir
defmodule MyApp.MCPTest do
  use ExUnit.Case, async: true
  import Sake.Test

  test "greets" do
    client = connect(MyApp.MCP, scope: user_fixture(), scopes: ["issues:read"])

    assert {:ok, %{text: "Hello, Rui!"}} = call_tool(client, "greet", %{"name" => "Rui"})
    assert {:ok, tools} = list_tools(client)
    refute "close_issue" in Enum.map(tools, & &1.name)

    assert {:error, {:insufficient_scope, %{scope: ["issues:write"]}}} =
             call_tool(client, "close_issue", %{"id" => 1})
  end
end
```

## What runs

The client is a `Sake.Client` whose transport is the server itself.
Every request crosses as JSON — `%{sum: 3}` in a tool comes back as
`%{"sum" => 3}`, as it would over HTTP — into the same dispatchers
`Sake.Plug` and `Sake.Stdio` use, with a real `Sake.Context`. Argument
validation, scope checks, results, errors, telemetry and traces are the
production ones; only HTTP is missing.

Most of Sake runs without anything started. A few features need the
stream registry or tasks: a legacy server's questions, `listen/2`, and
tools that run as tasks. When your application starts `{Sake, ...}` in
the test environment they are already there; otherwise start them once,
in `test/test_helper.exs`:

```elixir
Sake.Test.start()
ExUnit.start()
```

`start/1` leaves alone what already runs, and takes `tasks:` (the
`Sake.Tasks` options, or `false`).

### Beside `Phoenix.ChannelTest`

`Phoenix.ChannelTest`, which a `ChannelCase` imports, has a `connect`
macro of the same name and arity as `connect/2`, so a test that imports
both cannot call either unqualified. `mcp_connect/2` is `connect/2` under
another name; leave `Sake.Test`'s `connect` out of the import:

```elixir
import Phoenix.ChannelTest
import Sake.Test, except: [connect: 1, connect: 2]

client = mcp_connect(MyApp.MCP, scope: user)
```

(Or keep `Sake.Test`'s and leave out the channel one, with
`import Phoenix.ChannelTest, except: [connect: 2, connect: 3]`.)
`Phoenix.ConnTest` has no `connect` and imports beside `Sake.Test` as
it is.

The assertions below read best without parentheses; with `:sake` in the
`import_deps` of your `.formatter.exs`, `mix format` leaves them so.

## Calls and results

`connect/2` returns a client, and the calls are `Sake.Client`'s:
`list_tools/1`, `call_tool/3`, `call_tool_async/3`, `get_task/2`,
`update_task/3`, `cancel_task/2`, `list_resources/1`,
`list_resource_templates/1`, `read_resource/2`, `list_prompts/1`,
`get_prompt/3`, `complete/4`, `ping/1`, `set_log_level/2` and `close/1`,
plus `await_task/3` (below). They return what `Sake.Client`'s return
without the session — `{:ok, value}`, `{:error, reason}`, or `:ok` for a
call with nothing to return — because the client keeps its session in a
process of its own between calls. The process is linked to the one that
connected, so it ends with the test. `session/1` returns the session for
a test that wants `Sake.Client` itself.

`call_tool/3` returns a `Sake.Client.ToolResult`, with the tool's `text`,
`content`, `structured` content, `is_error` and `meta`. A tool error
(`{:error, text}` from `execute/2`, or arguments that do not validate) is
`{:ok, %ToolResult{is_error: true}}`, as the protocol has it; a JSON-RPC
error is `{:error, {:rpc, %{"code" => code, "message" => message}}}`, as
`Sake.Client` reports it over stdio:

```elixir
assert {:ok, %{is_error: true, text: "Invalid arguments: " <> _}} = call_tool(client, "add", %{"a" => "x"})
assert {:error, {:rpc, %{"code" => -32_602}}} = call_tool(client, "nope")
assert {:ok, [%Sake.Content{text: text}]} = read_resource(client, "issue://1")
```

The protocol era is modern unless you pass `era: :legacy` (and
`legacy_version:` to pick a revision); the client then runs the
`initialize` handshake and keeps the session's ID, which carries the
negotiated revision, the client's capabilities and its log level, as on
HTTP. A test that matters on both eras can run on both:

```elixir
for era <- [:modern, :legacy] do
  test "greets on #{era}" do
    client = connect(MyApp.MCP, era: unquote(era))
    assert {:ok, %{text: "Hello, Rui!"}} = call_tool(client, "greet", %{"name" => "Rui"})
  end
end
```

## The principal and scopes

`scope:` is the host's principal, what components see in `ctx.scope`
(a value, or a function of no arguments called for every request). It
stands for what `Sake.Plug`'s `scope:` or the bearer token's subject
would give your server.

Without `scopes:` there is no token, as on an endpoint without
authorization: every component is visible and callable. `scopes:`
simulates an access token with those scopes, and the real checks apply:
`list_tools/1` and the other lists leave out what the token does not
cover, and a call to it is refused as an endpoint with authorization
refuses it, with the scopes it needs:

```elixir
client = connect(MyApp.MCP, scope: user, scopes: ["issues:read"])
assert {:error, {:insufficient_scope, %Sake.Auth.Challenge{scope: ["issues:write"]}}} =
         call_tool(client, "close_issue", %{"id" => 1})
```

The token's subject owns the tasks the client starts (see
`guides/tasks.md`). It defaults to one derived from `scope:`, so two
clients with different principals are two people; `subject:` sets it.
`subject: nil` makes a machine client's token, as the client credentials
grant issues, owned by its `client_id:` (default `"sake-test"`):

```elixir
connect(MyApp.MCP, scope: service, scopes: ["issues:read"], subject: nil, client_id: "nightly-report")
```

The token is a `Sake.Auth.TokenRecord` in `ctx.token`, as Sake's bearer
check leaves it; nothing is stored, and `Sake.Auth` need not be
configured.

## The endpoint's URL

A tool that builds absolute URLs to its host reads `ctx.base_url` (see
`Sake.Context`). The in-memory client has no request to take it from,
so it is `nil`, as over stdio, unless the test gives one:

```elixir
client = connect(MyApp.MCP, scope: user, base_url: "https://example.com/acme/mcp")
assert {:ok, %{structured: %{"upload_url" => "https://example.com/uploads/" <> _}}} =
         call_tool(client, "start_upload", %{"name" => "a.jpg"})
```

Through a plug (below) `Sake.Plug` sets it from the request, as in
production: `http://www.example.com` and the `path:`.

`acr:` and `auth_time:` say how and when the token's person signed in,
for components with `authentication:` (see "Step-up authentication" in
`guides/tools.md`). A token without them meets no requirement:

```elixir
client = connect(MyApp.MCP, scopes: ["repos:admin"], acr: "pwd", auth_time: DateTime.utc_now())
assert {:error, {:insufficient_user_authentication, %Sake.Auth.Challenge{acr_values: ["mfa"]}}} =
         call_tool(client, "delete_repo", %{"name" => "x"})

client = connect(MyApp.MCP, scopes: ["repos:admin"], acr: "mfa", auth_time: DateTime.utc_now())
assert {:ok, _} = call_tool(client, "delete_repo", %{"name" => "x"})
```

`Sake.Test.access_token/1` takes the same two, for a test through the
whole stack.

## Answering the server

`on_input:`, `sampling:` and `roots:` answer the server's elicitation,
sampling and roots requests and turn on their capabilities, as for
`Sake.Client` (see `guides/client.md`). Without one, the server sees a
client that cannot answer — `{:error, :unsupported}` in the component.
Two shorter forms suit tests: `on_input:` may be a function of one
request's `params` returning `{:accept, content}`, `:decline`, `:cancel`
or an answer map, and `sampling:` a function of the request's `params`
returning the text of the reply (or `{:ok, result}`, `{:error, error}`).

```elixir
client =
  connect(MyApp.MCP,
    on_input: fn %{"message" => "Who should be greeted?"} -> {:accept, %{"name" => "Rui"}} end,
    sampling: fn _params -> "A one-line summary." end,
    roots: [%{"uri" => "file:///work", "name" => "Work"}]
  )
```

The answers reach the server however it asks: in a modern retry with
the signed request state, on a legacy call's stream, or through a task.
Every request is also recorded, for `assert_asked/2` and `refute_asked/2`
(the method, and a pattern for its params):

```elixir
assert {:ok, %{text: "Hello, Rui!"}} = call_tool(client, "greet", %{})
assert_asked "elicitation/create", %{"mode" => "form", "message" => "Who should be greeted?"}
```

## Progress and log messages

The client asks for progress on every call, and every notification the
server sends during one is recorded, for `assert_notification/2` and
`refute_notification/2`. Log messages need a level: `log_level:` on
`connect/2`, or `set_log_level/2`.

```elixir
client = connect(MyApp.MCP, log_level: :info)
assert {:ok, _} = call_tool(client, "import", %{"file" => "a.csv"})
assert_notification "notifications/progress", %{"progress" => 10, "total" => 10}
assert_notification "notifications/message", %{"level" => "info", "data" => %{"rows" => 10}}
```

`on_notification:` still sees each one too.

## Tasks

A tool declared with `task:` runs as a task, in the background, as it
does in production (`Sake.Client` declares the tasks extension by
default; `tasks: false` leaves it out). `call_tool/3` follows the task to
its result, answering its questions with `on_input:` and the others.
`call_tool_async/3` hands the task back instead, for a test that drives
it step by step:

```elixir
client = connect(MyApp.MCP, on_input: fn _ -> :cancel end)
assert {:ok, {:task, %{"taskId" => id}}} = call_tool_async(client, "export", %{})
assert {:ok, %{"status" => "input_required", "inputRequests" => %{"format" => _}}} = await_task(client, id)

:ok = update_task(client, id, %{"format" => %{"action" => "accept", "content" => %{"format" => "csv"}}})
assert {:ok, %{"status" => "completed", "result" => result}} = await_task(client, id)
```

`await_task/3` waits until the task is no longer `working` and returns
it as `tasks/get` does then; `cancel_task/2` cancels it. Neither it nor
`call_tool/3` sleeps through the task's poll interval: the client sees
the task's broadcasts, and polls again the moment its status changes,
so a test takes as long as the tool and no longer.

## Broadcasts

`listen/2` records what a server broadcasts —
`Sake.Server.notify_list_changed/2` and `Sake.Server.resource_updated/2`
— for `assert_list_changed/1` and `assert_resource_updated/1` (and their
`refute_` forms):

```elixir
listen(MyApp.MCP)
{:ok, _} = MyApp.Issues.close(issue)
assert_resource_updated "issue://#{issue.id}"
refute_list_changed :tools
```

It records the broadcasts made by the test process and by the processes
it started — a tool the test called, a task, a `Task` — and not those of
other tests running at the same time, so the test can be `async: true`.
A broadcast from a process the test did not start, a GenServer of your
application, say, needs `listen(MyApp.MCP, shared: true)`, which records
every broadcast of the server, from anywhere; such a test should be
`async: false`.

## MCP Apps

`ui: true` connects as a host that renders MCP Apps (see
`guides/apps.md`): the server lists its app-only tools and UI resources,
and each `Sake.Tool.Spec` from `list_tools/1` carries its app's `ui://`
URI and `visibility`. Without it the client is a plain one, which never
sees them.

## Exceptions

An exception in a component fails the test with that exception and its
stack trace, rather than coming back as the `"The tool failed."` result
a client would get. `reraise: false` gives the client's view instead,
for a test of that.

## Through the whole stack

The in-memory client skips HTTP, and with it your router, its
pipelines, and Sake's bearer check. `plug:` keeps them: the client
sends its requests over HTTP as it does over the network, and Req runs
the plug in the test's process instead of sending them to a socket.

```elixir
client =
  connect(MyApp.MCP,
    plug: MyAppWeb.Endpoint,
    path: "/acme/mcp",
    scopes: ["issues:read"],
    subject: user.id
  )

assert {:ok, tools} = list_tools(client)
```

`plug:` is the host's endpoint or router (started, as for
`Phoenix.ConnTest`), or `{Sake.Plug, server: MyApp.MCP}` for Sake's own
endpoint alone; `path:` is where the endpoint is mounted (default
`"/mcp"`), and `headers:` go with every request. The stack computes the
principal from the request, so `scope:` does not apply. With `scopes:`,
the client sends a real access token for `subject:` (the ID your subject
module's `fetch/1` takes) and that endpoint's URL, issued in the
`Sake.Auth` store by `access_token/1`, which a `Phoenix.ConnTest` test
can use too. When the server takes DPoP-bound tokens only (`dpop:
[required: true]`), the token is bound to a key instead, and the client
signs a proof with it for every request; the in-memory client has no
HTTP and no token to bind, and works as before:

```elixir
token = Sake.Test.access_token(subject: user.id, scopes: ["issues:read"], resource: "http://www.example.com/acme/mcp")
```

Everything the client checks over the network is checked here: the
`Mcp-*` headers (an argument mirrored into a header is sent once the
client has listed the tool, as a client does before a call), the
`Origin` and the token's audience. Two things need the in-memory client
instead: a legacy server's questions, which travel on the call's
response stream while the client answers with a request of its own, and
tasks followed without waiting, since through a plug the client polls a
task at the interval the server suggests. A test configuration can
shorten it: `tasks: [poll_interval: 10]` on the `Sake` child.

## Async tests

Every client has its own session, and a request runs in a process of
the test's own, so tests that connect can run with `async: true`. What
is shared is shared by IDs no test can guess: tasks (each bound to its
principal, too) and a legacy server's questions. Broadcasts are
recorded per test, as above.

Cursors and request states are signed with the `Sake` configuration's
secret when there is one, else a fixed secret every test client shares
(`secret:` sets one), so a request state one client obtained is refused
to another for its principal, as in production.
