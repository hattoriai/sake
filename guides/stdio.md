# Stdio

A local MCP client (Claude Desktop, Claude Code, an editor) can launch
a server as a subprocess and talk to it over the subprocess's standard
input and output, one JSON-RPC message per line. `Sake.Stdio` serves the
same `Sake.Server` module you mount with `Sake.Plug` this way, and
`Sake.Client` can launch and talk to any stdio server.

## Running a server

### From a Mix project

```
mix sake.stdio MyApp.MCP
```

The task starts your application, then serves `MyApp.MCP` until standard
input closes. Mix's own messages are silenced and the default `Logger`
handler moves to standard error, so standard output carries nothing but
MCP messages. Run `mix compile` once before handing the command to a
client: a dependency compiled on the first run can still print to
standard output before the task gets to silence it.

Register it with Claude Code from the project's directory:

```
claude mcp add --transport stdio my-app -- mix sake.stdio MyApp.MCP
```

### From a release

Add the server to your supervision tree, after `Sake`:

```elixir
children = [
  {Sake, secret_key_base: ...},
  {Sake.Stdio, server: MyApp.MCP}
]
```

When standard input closes, requests still running get two seconds
(`grace:`) to finish, and then the child stops the VM (`halt: false`
keeps it running instead). Since the release logs while it boots, before
the child starts, move the default `Logger` handler to standard error in
its configuration too:

```elixir
# config/runtime.exs
config :logger, :default_handler, config: [type: :standard_error]
```

A release usually serves HTTP as well; start the child only when the
release is launched as a stdio server, for instance from an environment
variable the client sets. Claude Desktop launches it from
`claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "my-app": {
      "command": "/opt/my_app/bin/my_app",
      "args": ["start"],
      "env": {"MY_APP_MCP_STDIO": "1", "MY_APP_TOKEN": "..."}
    }
  }
}
```

### From your own code

`Sake.Stdio.run/2` serves a server until standard input closes and
returns `:ok`; it is what `mix sake.stdio` calls, and what a script run
with `elixir` or `mix run` can call itself. `Sake` itself need not be
started: the stream registry the server needs starts with it when it is
missing.

## Standard output is the protocol

Anything on standard output that is not an MCP message breaks the
connection. While serving the real standard output, Sake moves the
default `Logger` handler to standard error and runs every request with
standard error as its group leader, so an `IO.puts/1` in a tool lands on
standard error. A `Logger` handler or backend of your own that writes to
standard output, or a library that writes to the `:user` device, still
needs moving or silencing.

## Authorization and the principal

A stdio server has no HTTP layer and no bearer tokens: the client that
launched it already chose to trust it, and the server takes its own
credentials from its environment. Pass the principal your components
see in `ctx.scope` as `scope:`, a value or a function of no arguments
called for every request:

```elixir
{Sake.Stdio,
 server: MyApp.MCP,
 scope: fn -> MyApp.Accounts.get_by_api_token!(System.fetch_env!("MY_APP_TOKEN")) end}
```

With no token, scope-gated components are all visible and callable: the
person who launched the process has whatever access the process has.

`secret:` signs pagination cursors and elicitation round trips, as on
HTTP. It defaults to the `Sake` configuration, else to a random secret
for the life of the process, which is enough: on stdio both only ever
travel between the process and its one client.

## What travels over stdio

Both protocol eras, on one connection. A request whose `_meta` names the
modern revision is served statelessly, exactly as on HTTP, with the same
`_meta` checks; an `initialize` request opens the connection's one
legacy session, which the process keeps (the negotiated revision, the
client's capabilities, the `logging/setLevel` level), and requests
without a protocol version in `_meta` then belong to it. Before
`initialize`, such a request gets `-32600` "Not initialized"; an
unknown protocol version gets `-32022`. A 2025-03-26 session also takes
batches.

Every request runs in its own process, so a slow tool does not hold up
the others, and responses can arrive out of order.
`notifications/cancelled` stops the request it names and its response is
never written; an unknown or finished request ID is ignored.

Progress (when the request carries a `progressToken`) and log messages
(at or above the request's `logLevel`, or the session's level) go out as
notifications while the request runs. Elicitation is an `input_required`
result on the modern era, since a modern stdio server never writes
requests, and an `elicitation/create` request the client answers on
standard input on the legacy era.

`subscriptions/listen` is acknowledged, then every notification it asked
for carries its subscription ID in `_meta`; it ends when the client
cancels it, or with its final result when the server stops. A legacy
session's `resources/subscribe` gets `notifications/resources/updated`
for its URIs, and list changes reach it unasked.
`Sake.Server.notify_list_changed/2` and `Sake.Server.resource_updated/2`
reach stdio clients the same way they reach HTTP ones.

A line that is not JSON gets a `-32700` error with a `null` id, and one
that is not JSON-RPC a `-32600`; the server keeps serving.

## The client side

`Sake.Client.connect/2` takes `{:stdio, command, args}` in place of a URL:

```elixir
{:ok, session} =
  Sake.Client.connect({:stdio, "npx", ["-y", "@modelcontextprotocol/server-everything"]},
    env: %{"API_KEY" => key},
    stderr: :ignore
  )

{:ok, tools, session} = Sake.Client.list_tools(session)
:ok = Sake.Client.close(session)
```

The command is looked up on the `PATH` unless it contains a `/`. Options:
`env:` (a `nil` value unsets a variable), `cd:`, `stderr:` (`:inherit`,
the default, shares this VM's standard error; `:ignore` discards the
server's), `probe_timeout:` and `close_timeout:`, plus every option
`connect/2` takes over HTTP except `headers:` and `req:`. The session
holds the process that owns the subprocess, linked to the caller.

Without `era:`, the client probes as the stdio transport asks: it sends
`server/discover`, stays modern on an answer or on an error only a modern
server sends, and falls back to `initialize` on any other error or when
no answer comes within `probe_timeout:` (10 seconds).

`close/1` closes the server's standard input, waits up to
`close_timeout:` (5 seconds) for it to exit, then sends `SIGTERM`, then
`SIGKILL`. A server that exits on its own fails the calls in flight with
`{:error, :closed}`.
