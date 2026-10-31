defmodule Sake.Tasks do
  @moduledoc """
  Tools that run as tasks: the `io.modelcontextprotocol/tasks` extension
  of the modern protocol.

      defmodule MyApp.MCP.Export do
        use Sake.Tool, name: "export", task: :optional
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
                Sake.Progress.report(ctx, n + 1, length(files))
                {:cont, n + 1}
              end
            end)

          {:ok, "Exported \#{exported} of \#{length(files)} files."}
        end
      end

  When a client declares the extension in a request's capabilities, a
  call to a tool with `task: :optional` (or `true`) or `task: :required`
  answers at once with a task, and `execute/2` runs in the background; the
  client polls `tasks/get` until the task ends. Without the extension, an
  optional task tool runs like any other tool, and a required one is
  refused with `-32021`. Arguments and scopes are checked before a task
  exists, and a tool's `prepare/2` runs first, so it can still ask the
  client for input on the original request (see `Sake.Tool`).

  Inside a task, `Sake.Elicit`, `Sake.Sampling` and `Sake.Roots` move the
  task to `input_required` and wait for the client's `tasks/update`
  (keys must be unique over the task's life: asking a key again returns
  the first answer); `Sake.Progress.report/4` sets the task's
  `statusMessage`; `cancelled?/1` tells whether the client cancelled.
  Cancelling marks the task cancelled at once and stops its process when
  it runs on the node that received `tasks/cancel`; elsewhere, the tool
  sees the cancellation when it next waits for input (a cancelled
  elicitation, `{:error, :cancelled}` from sampling and roots) or calls
  `cancelled?/1`.

  A task belongs to whoever created it, and to what they created it
  through: the token's subject when the endpoint has authorization
  (otherwise the host's scope, see `Sake.Plug`'s `scope:`), together with
  the server, the token's OAuth client and its resource. Any other caller,
  the same person through another client, resource or server included, is
  told the task does not exist. Reading, answering, cancelling and
  following a task also need the scopes its tool required when it started:
  a token without them is refused with `insufficient_scope`, as the call
  itself would be. Task IDs carry 144 random bits.

  Tasks are configured on the `Sake` child:

      {Sake, secret_key_base: ..., tasks: [store: {Sake.Tasks.Store.Ecto, repo: MyApp.Repo}]}

  Options: `store` (default `Sake.Tasks.Store.ETS`, which keeps tasks on
  one node; use `Sake.Tasks.Store.Ecto` when the endpoint runs on
  several), `ttl` (how long a task is kept after it was created, in ms;
  default one hour), `poll_interval` (the `pollIntervalMs` suggested to
  clients, and how often a waiting task checks the store; default one
  second), `max_per_principal` (how many live tasks one owner may
  have at once, see below; default 100, or `:infinity`), `runner` (where
  the tools run, a `Sake.Tasks.Runner`; default
  `Sake.Tasks.Runner.Local`, a process of the node that started the task)
  and `lease` (how long a run holds its task without renewing, in ms;
  default 30 seconds, see "Recovery"). `tasks: false` turns tasks off:
  task tools then run like any other tool, and the extension is not
  advertised.

  ## State and execution

  The store keeps a task's state (its status, input requests and answers,
  result); the runner executes its tool. A persistent store
  (`Sake.Tasks.Store.Ecto`) lets any node answer for a task, but does not
  by itself keep the run going: with the default runner, the run is a
  process of the node that started it, and goes with that node.

  ## Recovery

  A run holds a lease on its task, which it renews every third of `lease`
  while it lives, waiting for the client's input included. When the node
  running it goes away (a deploy, a crash), the lease lapses, and the
  reaper of any node (every half lease) recovers the task, under its
  tool's `recovery:` option:

    * `:fail` (the default) — the task fails: `-32603`, "The task's worker
      stopped before the task ended.", with `data.reason` `"worker_lost"`.
      A client polling it sees a terminal status, not `working` forever.
    * `{:retry, attempts}` — the task runs again, from the start, with the
      same arguments and request context, through the runner, until it
      has run `attempts` times in all; then it fails as above. Answers
      the client already gave are kept: a run that asks the same key again
      gets the same answer at once, so a task that was waiting for input
      keeps waiting for the same question.

  Retrying is at least once, never exactly once: the run that died may
  have done some of its work (sent the email, charged the card) before
  it did. Opt a tool in only when running it again is harmless, or when
  it makes itself idempotent (by the task's ID, `ctx.task`).

  A run records its outcome only while it holds the lease: a run that
  stalled past its lease and was replaced, or a job delivered twice,
  never overwrites the task. Only a store every node shares
  (`Sake.Tasks.Store.Ecto`) lets another node find an orphan; with the
  ETS store, a node's tasks are gone with it anyway. A custom store
  recovers tasks once it implements `Sake.Tasks.Store`'s `orphans/2`.

  A runner whose jobs survive the node themselves (a durable queue, see
  `Sake.Tasks.Runner`) says so with `recovers?/0`: Sake then leaves its
  tasks to it, and they end when the queue runs them, or expire.

  ## External jobs

  A tool may hand its task to a job it does not run itself (a provider's
  export API, a build system) by returning `{:external, handle}` from
  `execute/2`. The task keeps working, with no lease to lapse, until the
  host reports the job's outcome, from a webhook say, with
  `complete/3` or `fail/3` (and `progress/5` meanwhile), or the task
  expires. A cancelled task ignores the job's report.

  An owner with `max_per_principal` tasks neither ended nor expired gets
  no new one until one ends: a `task: :optional` tool then runs like any
  other tool, in the request, and a `task: :required` tool (or a proxied
  call the upstream made a task of, which is cancelled upstream) is
  refused with `-32600`.

  Telemetry: `[:sake, :task, :start | :stop | :exception]` around the
  tool's run, with `task_id`, `tool` and `server` in the metadata, and the
  final `status` on `:stop`. With OpenTelemetry, the run is an
  `execute_tool` span, the child of the span of the `tools/call` that
  started it (see `guides/observability.md`).
  """

  alias Sake.Context
  alias Sake.Tasks.Record

  @extension "io.modelcontextprotocol/tasks"
  @defaults [
    store: {Sake.Tasks.Store.ETS, []},
    runner: Sake.Tasks.Runner.Local,
    ttl: 3_600_000,
    poll_interval: 1_000,
    max_per_principal: 100,
    lease: 30_000
  ]

  @doc "Whether the client asked to cancel the task the component runs in; always `false` outside a task."
  @spec cancelled?(Context.t()) :: boolean()
  def cancelled?(%Context{task: id}) when is_binary(id) do
    case fetch(id) do
      {:ok, %Record{status: :cancelled}} -> true
      {:ok, _record} -> false
      :error -> true
    end
  end

  def cancelled?(_ctx), do: false

  @doc false
  def extension, do: @extension

  @doc false
  # Whether tasks run on this node: without them (`tasks: false`), task
  # tools run like any other tool and the extension is not advertised.
  def running?, do: Process.whereis(__MODULE__.Registry) != nil

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, type: :supervisor, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc false
  def start_link(opts) do
    opts = Keyword.merge(@defaults, opts)
    {module, store_opts} = opts[:store]

    :persistent_term.put({__MODULE__, :config}, %{
      store: {module, module.init(store_opts)},
      runner: runner!(opts[:runner]),
      ttl: opts[:ttl],
      poll_interval: opts[:poll_interval],
      max_per_principal: opts[:max_per_principal],
      lease: lease!(opts[:lease])
    })

    store =
      if function_exported?(module, :child_spec, 1), do: [module.child_spec(store_opts)], else: []

    children =
      store ++
        [
          {Registry, keys: :duplicate, name: __MODULE__.Registry},
          {Task.Supervisor, name: __MODULE__.Supervisor},
          __MODULE__.Pruner
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Root)
  end

  defp runner!({module, opts} = runner) when is_atom(module) and is_list(opts) do
    Code.ensure_loaded!(module)

    if not function_exported?(module, :start, 2) do
      raise ArgumentError, "tasks: runner: #{inspect(module)} is not a Sake.Tasks.Runner"
    end

    runner
  end

  defp runner!(module) when is_atom(module), do: runner!({module, []})

  defp runner!(other),
    do:
      raise(
        ArgumentError,
        "tasks: runner: must be a module or {module, opts}, got #{inspect(other)}"
      )

  defp lease!(ms) when is_integer(ms) and ms >= 30, do: ms

  defp lease!(other),
    do: raise(ArgumentError, "tasks: lease: must be at least 30 ms, got #{inspect(other)}")

  # ---- running a task: the public side of `Sake.Tasks.Runner`

  @doc """
  Runs the task of `job` in the calling process, and records how it
  ended: what a `Sake.Tasks.Runner` calls once the job reached the process
  that should run it (a durable queue's worker, say).

  The run first claims the task. It does nothing, and returns
  `{:skipped, reason}`, when the task already ended (`:ended`), expired
  (`:expired`), was handed to an external job (`:external`), or is held
  by another run whose lease has not lapsed (`:running`): a job delivered
  twice, or again after its task ended, runs the tool once per claim.
  Otherwise it executes the tool with the context of the request that
  started the task, renews the task's lease while it runs (or waits for
  the client's input), and returns the task's final status (`:completed`,
  `:failed`, `:cancelled`; `:external` once handed to an external job;
  `:expired` when the task expired meanwhile). A run that lost its lease
  to another (it stalled past it, and the task was recovered) does not
  record its outcome over the other's.
  """
  @spec run(Sake.Tasks.Job.t()) :: Record.status() | :external | :expired | {:skipped, atom()}
  def run(%Sake.Tasks.Job{} = job), do: Sake.Tasks.Worker.run(job)

  @doc """
  Completes a task that a tool handed to an external job (by returning
  `{:external, handle}` from `execute/2`): `result` is what `execute/2`
  would have returned (`{:ok, value}`, `{:ok, value, opts}`,
  `{:error, text}`), and goes through the tool's result handling and its
  `:after_call` middleware as if it had. `handle` must be the one the
  tool returned. `:error` when the task is unknown, ended, expired, or
  not that job's.
  """
  @spec complete(String.t(), String.t(), term()) :: :ok | :error
  def complete(task_id, handle, result) when is_binary(task_id) and is_binary(handle),
    do: Sake.Tasks.Worker.report(task_id, handle, result)

  @doc """
  Fails a task that a tool handed to an external job: the client gets
  `-32603` with `message`. See `complete/3`.
  """
  @spec fail(String.t(), String.t(), String.t()) :: :ok | :error
  def fail(task_id, handle, message) when is_binary(message),
    do: Sake.Tasks.Worker.report(task_id, handle, {:failed, message})

  @doc """
  Reports an external job's progress, as `Sake.Progress.report/4` does
  from inside a task: the task's `statusMessage`. See `complete/3`.
  """
  @spec progress(String.t(), String.t(), number(), number() | nil, String.t() | nil) ::
          :ok | :error
  def progress(task_id, handle, current, total \\ nil, message \\ nil),
    do: Sake.Tasks.Worker.external_progress(task_id, handle, current, {total, message})

  @doc false
  def config do
    :persistent_term.get({__MODULE__, :config}, nil) ||
      raise "Sake.Tasks is not running: add {Sake, ...} to your supervision tree"
  end

  # ---- the store, as the rest of Sake uses it: expired tasks are gone.

  @doc false
  # The new task, or `:full` when its owner already has
  # `max_per_principal` live tasks.
  @spec create(Context.t(), String.t(), [String.t()]) :: {:ok, Record.t()} | :full
  def create(ctx, tool, scopes \\ []) do
    %{store: {module, state}, ttl: ttl, poll_interval: poll, max_per_principal: max} = config()
    now = now()

    record = %Record{
      id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      principal: owner(ctx),
      tool: tool,
      scopes: scopes,
      ttl_ms: ttl,
      poll_interval_ms: poll,
      created_at: now,
      updated_at: now,
      expires_at: DateTime.add(now, ttl, :millisecond)
    }

    case module.insert(state, record, max) do
      :ok -> {:ok, record}
      :full -> :full
    end
  end

  @doc false
  @spec fetch(String.t()) :: {:ok, Record.t()} | :error
  def fetch(id) do
    %{store: {module, state}} = config()

    case module.get(state, id) do
      {:ok, record} -> if Record.expired?(record, now()), do: :error, else: {:ok, record}
      :error -> :error
    end
  end

  @doc false
  # Updates the task and, when its status changed, tells the listen
  # streams of `server` on every node.
  @spec update(module(), String.t(), (Record.t() -> Record.t())) :: {:ok, Record.t()} | :error
  def update(server, id, fun) do
    %{store: {module, state}} = config()
    now = now()

    case module.update(state, id, &touch(&1, fun.(&1), now)) do
      {:ok, before, updated} ->
        cond do
          Record.expired?(before, now) ->
            :error

          before.status != updated.status ->
            Sake.Plug.Streams.broadcast(server, {:task, Record.to_wire(updated)})
            {:ok, updated}

          true ->
            {:ok, updated}
        end

      :error ->
        :error
    end
  end

  # A renewed lease is not a change the client sees: `lastUpdatedAt`
  # moves only when something on the wire does.
  @lease [:lease_owner, :lease_until]

  defp touch(before, updated, now) do
    if Map.drop(before, @lease) == Map.drop(updated, @lease),
      do: updated,
      else: %{updated | updated_at: now}
  end

  @doc false
  # Whom a task is bound to, and through what: the principal, the server,
  # and the token's client and resource. The same person's token for
  # another client (a narrower integration) or another resource (another
  # tenant's endpoint), or a request to another server sharing the store,
  # is not the task's owner. Kept as a digest, since the store may be a
  # database and a principal can be long. A multi round-trip request's
  # signed state is bound the same way (`Sake.Server.RequestState`).
  @spec owner(Context.t()) :: String.t()
  def owner(%Context{} = ctx) do
    token = ctx.token || %{}

    binding = [
      principal(ctx) || "",
      inspect(ctx.server),
      to_string(Map.get(token, :client_id) || ""),
      to_string(Map.get(token, :resource) || "")
    ]

    # Each part length-prefixed, so no two bindings hash the same input.
    digest = :crypto.hash(:sha256, Enum.map(binding, &[Integer.to_string(byte_size(&1)), ?:, &1]))
    "owner:" <> Base.url_encode64(digest, padding: false)
  end

  @doc false
  # The principal a task's owner names (see `owner/1`): the token's
  # subject (or its client), else the host's scope (as
  # `Sake.Server.RequestState` binds a request state). The scope is kept as
  # a digest, since the store may be a database.
  #
  # A token from an external authorization server is that issuer's: the
  # same `sub` from another issuer, or from `Sake.Auth`, is someone else.
  @spec principal(Context.t()) :: String.t() | nil
  def principal(%Context{token: %{issuer: iss} = token} = ctx) when is_binary(iss) do
    issuer =
      :sha256 |> :crypto.hash(iss) |> binary_part(0, 16) |> Base.url_encode64(padding: false)

    case principal(%{ctx | token: %{token | issuer: nil}}) do
      nil -> nil
      local -> "issuer:" <> issuer <> ":" <> local
    end
  end

  def principal(%Context{token: %{subject_id: id}}) when is_binary(id), do: "subject:" <> id

  # A machine client's token (client credentials) has no subject: the
  # client is the principal.
  def principal(%Context{token: %{subject_id: nil, client_id: id}}) when is_binary(id),
    do: "client:" <> id

  def principal(%Context{scope: nil}), do: nil

  def principal(%Context{scope: scope}),
    do: "scope:" <> Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(scope)))

  @doc false
  # Wakes this node's processes waiting on the task, so an answer or a
  # cancellation is seen at once rather than at the next poll.
  def wake(id), do: dispatch(id, &send(&1, {:sake_task_wake, id}))

  @doc false
  # Stops this node's processes running the task.
  def stop(id), do: dispatch(id, &Process.exit(&1, :kill))

  defp dispatch(id, fun) do
    if Process.whereis(__MODULE__.Registry),
      do: Registry.dispatch(__MODULE__.Registry, id, &each_pid(&1, fun))

    :ok
  end

  defp each_pid(entries, fun), do: Enum.each(entries, fn {pid, _} -> fun.(pid) end)

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond)

  @doc false
  # Recovers the store's orphans now (the reaper does every half lease):
  # how many it ran again and failed. For a test, or an operator.
  @spec reap() :: %{retried: non_neg_integer(), failed: non_neg_integer()}
  def reap do
    %{store: {module, store}} = config()

    orphans =
      if function_exported?(module, :orphans, 2) and not Sake.Tasks.Runner.recovers?(),
        do: module.orphans(store, now()),
        else: []

    orphans
    |> Enum.map(&Sake.Tasks.Worker.recover/1)
    |> Enum.reduce(%{retried: 0, failed: 0}, fn
      :retried, acc -> %{acc | retried: acc.retried + 1}
      :failed, acc -> %{acc | failed: acc.failed + 1}
      :skipped, acc -> acc
    end)
  end

  defmodule Pruner do
    @moduledoc false
    # Deletes expired tasks from the store every minute, and recovers
    # orphans (tasks whose run's lease lapsed) every half lease. Several
    # nodes pruning and reaping the same database is harmless: each
    # orphan is recovered by one of them (`Sake.Tasks.Worker.recover/1`).
    use GenServer

    require Logger

    @prune 60_000

    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @impl true
    def init(nil) do
      Process.send_after(self(), :prune, @prune)
      Process.send_after(self(), :reap, reap_interval())
      {:ok, nil}
    end

    @impl true
    def handle_info(:prune, state) do
      %{store: {module, store}} = Sake.Tasks.config()
      :ok = module.prune(store, Sake.Tasks.now())
      Process.send_after(self(), :prune, @prune)
      {:noreply, state}
    end

    def handle_info(:reap, state) do
      try do
        Sake.Tasks.reap()
      rescue
        exception ->
          Logger.error("Sake.Tasks could not recover orphans: " <> Exception.message(exception))
      end

      Process.send_after(self(), :reap, reap_interval())
      {:noreply, state}
    end

    defp reap_interval, do: max(div(Sake.Tasks.config().lease, 2), 10)
  end
end
