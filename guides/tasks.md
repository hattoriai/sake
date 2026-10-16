# Tasks

A tool that takes longer than a request should wait — an export, a
report, anything that calls a slow service — can run as a *task*: the
call answers at once with a task ID, the work goes on in the background,
and the client polls for the result. This is the
`io.modelcontextprotocol/tasks` extension of the 2026-07-28 protocol.

## Declaring a task tool

```elixir
defmodule MyApp.MCP.Export do
  use Sake.Tool, name: "export", description: "Exports a project", task: :optional
  arg :project, :string, required: true

  @impl true
  def execute(%{project: project}, ctx) do
    files = Projects.files(project)

    exported =
      Enum.reduce_while(files, 0, fn file, n ->
        if Sake.Tasks.cancelled?(ctx) do
          {:halt, n}
        else
          Export.file(file)
          Sake.Progress.report(ctx, n + 1, length(files), "Exported #{file.name}")
          {:cont, n + 1}
        end
      end)

    {:ok, "Exported #{exported} of #{length(files)} files."}
  end
end
```

`task: :optional` (or `task: true`) runs the tool as a task when the
client declares the extension in the request's capabilities, and like any
other tool when it does not. `task: :required` refuses a client without
the extension with `-32021`, naming the extension in
`data.requiredCapabilities`. Clients declare the extension per request,
so the same client may get a task on one call and a plain result on
another; `Sake.Client` declares it by default.

The server decides, the client never asks: there is no task parameter on
the call, and a legacy session (2025-11-25 and earlier) never gets a task
— its optional task tools run synchronously, and its required ones are
refused.

## What happens on a call

1. The arguments are validated and the scopes checked, exactly as for
   any tool. Errors here are ordinary results or errors; no task exists.
2. The tool's `prepare/2`, if it has one, runs in the request (below).
3. Sake stores the task, starts `execute/2` in a supervised process, and
   answers with the task: `resultType: "task"`, `taskId`, `status:
   "working"`, `createdAt`, `lastUpdatedAt`, `ttlMs` and
   `pollIntervalMs`. The task is stored *before* the answer, so a
   `tasks/get` right after it finds it, on any node.
4. The client polls `tasks/get`. While the tool runs the task is
   `working`; when the tool asks for input it is `input_required`, with
   the questions in `inputRequests`; when it ends it is `completed` (with
   `result`, the tool result exactly as a synchronous call returns it,
   `isError` tool errors included) or `failed` (with `error`, a JSON-RPC
   error: the tool raised, `-32603`, or refused for want of a capability,
   `-32021`).

`tasks/get`, `tasks/update` and `tasks/cancel` need the extension in the
request's capabilities too (`-32021` otherwise), and a task ID the caller
does not own — or one that expired — is `-32602` "Failed to retrieve
task: Task not found". On the Streamable HTTP transport these requests
carry the task ID in `Mcp-Name`, which Sake checks against the body like
every other mirrored header.

## Input inside a task

`Sake.Elicit`, `Sake.Sampling` and `Sake.Roots` work inside a task as
they do anywhere else, but travel differently: the call moves the task to
`input_required`, lists the request under its key in `inputRequests`, and
waits until the client answers through `tasks/update`. Unlike a modern
retry, nothing runs twice — the tool simply waits — so side effects
before the question are fine.

Keys are unique over a task's life: asking the same key again returns the
first answer. `Sake.Input.all/2` puts several questions on the task at
once, and the client may answer them in one update or in several; the
task stays `input_required` until every one is answered. An answer for a
key that is not outstanding is ignored.

### Asking before the task starts

When an answer decides whether the work should start at all, ask in
`prepare/2`. It runs in the request, so its questions are ordinary
multi round-trip requests on the original call, and the task is created
only on the round that completes them:

```elixir
defmodule MyApp.MCP.Purge do
  use Sake.Tool, name: "purge", task: :required
  arg :project, :string, required: true

  @impl true
  def prepare(args, ctx) do
    case Sake.Elicit.form(ctx, :confirm, "Purge #{args.project}?", %{
           "type" => "object",
           "properties" => %{"sure" => %{"type" => "boolean"}}
         }) do
      {:ok, %{"sure" => true}} -> {:ok, args}
      _ -> {:error, "Not purged."}
    end
  end

  @impl true
  def execute(%{project: project}, _ctx), do: {:ok, Projects.purge(project)}
end
```

`prepare/2` returns the arguments `execute/2` receives (so it can add the
answers to them), or `{:error, text}` for a tool error without a task.

## Progress and cancellation

`Sake.Progress.report/4` sets the task's `statusMessage` (the message, or
`"3/10"` without one); progress and log notifications are not sent for
tasks.

`tasks/cancel` is cooperative. Sake marks the task `cancelled` at once —
a task that already ended stays as it was, and the cancel is acknowledged
all the same — and stops the tool's process when it runs on the node that
received the cancel. On any other node the tool learns of it the next
time it waits for input (an elicitation reads as `:cancel`, sampling and
roots as `{:error, :cancelled}`) or calls `Sake.Tasks.cancelled?/1`, so a
long loop should check it now and then.

## Notifications

A client that declared the extension can follow its tasks on a
`subscriptions/listen` stream instead of polling:

```json
{"notifications": {"taskIds": ["Xb4...", "Qm9..."]}}
```

The acknowledgement lists the task IDs Sake agreed to — the caller's own,
live tasks; the others are silently left out — and every status change of
those tasks then arrives as `notifications/tasks` carrying the whole task,
as `tasks/get` would return it. Status changes go through
`Sake.Plug.Streams.broadcast/2`, so with a `pubsub:` they reach listen
streams on every node.

## Storage and nodes

Tasks live in a `Sake.Tasks.Store`. The default, `Sake.Tasks.Store.ETS`,
keeps them in memory on one node. An endpoint on several nodes needs a
shared store:

```elixir
defmodule MyApp.Repo.Migrations.AddSakeTasks do
  use Ecto.Migration
  def up, do: Sake.Tasks.Migration.up()
  def down, do: Sake.Tasks.Migration.down()
end
```

```elixir
{Sake,
 secret_key_base: ...,
 pubsub: MyApp.PubSub,
 tasks: [store: {Sake.Tasks.Store.Ecto, repo: MyApp.Repo}, ttl: :timer.hours(1), poll_interval: 1_000]}
```

The tool runs on the node that received the call; `tasks/get`,
`tasks/update` and `tasks/cancel` may land on any node, because workers
coordinate through the store: a worker waiting for input checks it every
`poll_interval` (and is woken at once when the update lands on its own
node). `poll_interval` is also the `pollIntervalMs` clients are told.

`tasks: false` on the `Sake` child turns tasks off: task tools then run
synchronously for every client, and `server/discover` does not advertise
the extension.

A task is kept for `ttl` after it was created (default one hour) — its
process is stopped then if it is still running — and is "not found"
afterwards; expired tasks are deleted from the store every minute.

## Security

Task IDs carry 144 random bits. A task belongs to the principal that
created it — the token's subject when the endpoint has authorization,
otherwise the host's scope (`Sake.Plug`'s `scope:`) — through the server,
OAuth client and resource it was created with, and every other caller
(the same person through another client, resource or server included)
is told it does not exist, on `tasks/get`, `tasks/update`,
`tasks/cancel` and `subscriptions/listen` alike. Each of them also needs
the scopes the tool required when the task started; a token without
them gets `insufficient_scope`. On an endpoint with neither
authorization nor a scope, the task ID itself is the only credential.

Input requests surfaced through a task are the same elicitation,
sampling and roots requests as anywhere else; a client applies the same
trust to them.

## Telemetry

`[:sake, :task, :start]`, `[:sake, :task, :stop]` and
`[:sake, :task, :exception]` surround the tool's run in the background,
with `task_id`, `tool` and `server` in the metadata and the final
`status` on `:stop` — next to the `[:sake, :server, :request]` span of
the call that created the task. With OpenTelemetry, the run is an
`execute_tool` span, the child of that call's span (see
`guides/observability.md`).

## Not supported

The in-core, experimental tasks of revision 2025-11-25 (`tasks/result`,
`tasks/list`, the `task` request parameter, `execution.taskSupport` on
tools) are not implemented: `tasks/result` and `tasks/list` are "method
not found", and a `task` parameter is ignored.
