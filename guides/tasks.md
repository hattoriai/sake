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
 tasks: [store: {Sake.Tasks.Store.Ecto, repo: MyApp.Repo}, ttl: :timer.hours(1), poll_interval: 1_000, max_per_principal: 100]}
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

Each owner (see Security below) may have `max_per_principal` live tasks
at once — neither ended nor expired — default 100 (`:infinity` lifts the
limit). Beyond it, a `task: :optional` tool runs in the request like any
other tool; a `task: :required` tool is refused with `-32600`, as is a
proxied call the upstream made a task of (the upstream's task is
cancelled). A task that ends frees its slot.

A table created before recoverable execution (below) needs its columns:
run `Sake.Tasks.Migration.add_execution/1` in a migration of its own.

## State and execution

These are two different things:

- **The store keeps a task's state:** its status, its input requests and
  answers, its result. A persistent store (`Sake.Tasks.Store.Ecto`) lets
  any node answer `tasks/get` for any task, and keeps the state across
  restarts.
- **The runner executes its tool.** The default,
  `Sake.Tasks.Runner.Local`, runs it in a process of the node that
  received the call. That process goes with its node: a persistent
  store keeps the task, but nothing keeps running it.

So Sake makes every run hold a **lease** on its task. A run renews the
lease every third of `lease` (default 30 seconds) while it lives,
waiting for the client's input included. When its node goes away (a
deploy, a crash, an out-of-memory kill), the lease lapses. The reaper of
every node (every half lease) finds such orphans in the store and
recovers each under its tool's `recovery:` option:

```elixir
use Sake.Tool, name: "export", task: :required              # recovery: :fail
use Sake.Tool, name: "reindex", task: :required, recovery: {:retry, 3}
```

| `recovery:` | When the run is lost |
|---|---|
| `:fail` (default) | The task fails: `-32603` "The task's worker stopped before the task ended.", with `data: {"reason": "worker_lost", "attempts": n}`. The client sees a terminal status, never `working` until expiry. |
| `{:retry, n}` | The task runs again, from the start, with the same arguments and request context, until it has run `n` times in all; then it fails as above. Answers the client already gave are kept, so a run that asks the same key again gets the same answer at once, and a task lost while waiting for input waits for the same question. |

Only a store every node shares lets another node see an orphan. With
the ETS store, a node's tasks are gone with it anyway. A custom store
recovers tasks once it implements `Sake.Tasks.Store`'s `orphans/2`.

### Retry guarantees

A retried task runs **at least once, never exactly once**. The run that
died may have done some of its work before it died: sent the email,
charged the card, written half the export. Sake never retries a tool
that did not opt in. When you opt one in, make running it again
harmless:

- **Key side effects on the task's ID** (`ctx.task`), which every run of
  the task shares: an idempotency key for a payment provider, the name
  of the file it writes.
- **Check before acting**, from state the tool itself records.

Sake guarantees the rest:

- **One run at a time.** A run first claims the task. A second delivery
  of a job (a queue's redelivery), or a run started while another holds
  a live lease, does nothing.
- **The current run's outcome wins.** A run records its outcome only
  while it holds the lease. A run that stalled past its lease and was
  replaced does not overwrite the task, though its side effects have
  happened.
- **An ended task stays ended.** A cancelled, completed, failed or
  expired task is never run again, and a late result is dropped.

## Durable queues

A runner (`Sake.Tasks.Runner`) decides where a task's tool runs. To run
tasks on a durable job system, give `tasks:` a runner that hands the job
to it, and have the job system's worker call `Sake.Tasks.run/1`:

```elixir
defmodule MyApp.TaskRunner do
  @behaviour Sake.Tasks.Runner

  @impl true
  def start(job, _opts) do
    %{"job" => Sake.Tasks.Job.encode(job)} |> MyApp.TaskWorker.new() |> Oban.insert()
    :ok
  end

  @impl true
  def cancel(task_id, _opts), do: MyApp.TaskWorker.cancel_for(task_id)

  # Oban runs a job again after its node dies: Sake's reaper leaves
  # these tasks to it.
  @impl true
  def recovers?, do: true
end

defmodule MyApp.TaskWorker do
  use Oban.Worker, queue: :sake_tasks, max_attempts: 3

  @impl true
  def perform(%Oban.Job{args: %{"job" => job}}) do
    case Sake.Tasks.Job.decode(job) do
      {:ok, job} ->
        Sake.Tasks.run(job)
        :ok

      :error ->
        {:cancel, "not a Sake job"}
    end
  end
end
```

```elixir
{Sake, secret_key_base: ..., tasks: [store: {Sake.Tasks.Store.Ecto, repo: MyApp.Repo}, runner: MyApp.TaskRunner]}
```

- **`Sake.Tasks.Job`** carries the task's ID, server, tool, validated
  arguments and request context (`ctx.scope` included, so keep the
  scope plain data). `encode/1` signs it with Sake's `secret_key_base`,
  and `decode/1` refuses anything else.
- **`Sake.Tasks.run/1`** runs the tool in the worker's process, with
  the original request's context. It returns `{:skipped, reason}` for a
  job whose task ended, expired, or is held by a live run, so the queue's
  redeliveries are harmless.
- **The original request** has long answered: the client polls
  `tasks/get` until the queue's worker records the outcome.

Sake does not depend on Oban or any queue: a runner is a module of
yours. A proxied tool's upstream task always runs in-process, since the
function that follows it cannot leave its node.

## External jobs

A tool whose work is done by another system (a provider's export API, a
CI pipeline) can hand the task to it. It returns `{:external, handle}`
from `execute/2`, and reports the outcome later, from the webhook that
system calls:

```elixir
def execute(%{project: project}, ctx) do
  {:ok, export_id} = ExportAPI.start(project, callback: url_for(ctx.task))
  {:external, export_id}
end

# in the webhook's controller, after checking the webhook's signature
:ok = Sake.Tasks.progress(task_id, export_id, done, total)
:ok = Sake.Tasks.complete(task_id, export_id, {:ok, %{"url" => url}})
:ok = Sake.Tasks.fail(task_id, export_id, "The export failed.")
```

- **While handed off:** the task stays `working` with no lease, since
  Sake does not watch the other system. It ends when the host reports
  it, or when it expires.
- **`complete/3`:** takes what `execute/2` could have returned, and runs
  it through the tool's result handling and `:after_call` middleware.
- **`fail/3`:** fails the task with `-32603`.
- **Refused reports:** both return `:error` for a task that ended (a
  cancelled one included), expired, or that the handle does not match.
- **Outside a task:** a tool that returns `{:external, handle}` when
  called without one gets a tool error, since there is no task to wait
  on.

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
with `task_id`, `tool`, `server` and `attempt` in the metadata and the final
`status` on `:stop` — next to the `[:sake, :server, :request]` span of
the call that created the task. With OpenTelemetry, the run is an
`execute_tool` span, the child of that call's span (see
`guides/observability.md`).

## Not supported

The in-core, experimental tasks of revision 2025-11-25 (`tasks/result`,
`tasks/list`, the `task` request parameter, `execution.taskSupport` on
tools) are not implemented: `tasks/result` and `tasks/list` are "method
not found", and a `task` parameter is ignored.
