defmodule Sake.Tasks.Runner do
  @moduledoc """
  Where a task's tool runs. The task's state lives in a
  `Sake.Tasks.Store`; the runner decides which process executes the
  tool, and whether that survives the node that started it.

  `start/2` gets the task's `Sake.Tasks.Job` and gets it to a process
  that calls `Sake.Tasks.run/1` with it, now or later, on this node or
  another. The default, `Sake.Tasks.Runner.Local`, runs it at once in a
  process of this node. A durable queue persists it and runs it from a
  worker of its own:

      defmodule MyApp.TaskRunner do
        @behaviour Sake.Tasks.Runner

        @impl true
        def start(job, _opts) do
          %{"job" => Sake.Tasks.Job.encode(job)}
          |> MyApp.TaskWorker.new()
          |> Oban.insert()

          :ok
        end

        # The queue runs the job again after a crash; Sake's leases need
        # not.
        @impl true
        def recovers?, do: true
      end

      defmodule MyApp.TaskWorker do
        use Oban.Worker, queue: :sake_tasks, max_attempts: 3

        @impl true
        def perform(%Oban.Job{args: %{"job" => job}}) do
          {:ok, job} = Sake.Tasks.Job.decode(job)
          Sake.Tasks.run(job)
          :ok
        end
      end

      {Sake, secret_key_base: ..., tasks: [store: {...}, runner: MyApp.TaskRunner]}

  `Sake.Tasks.run/1` claims the task before it executes the tool, so a
  queue that delivers a job twice, or runs it again after the task ended,
  runs the tool once per claim: a delivery that finds the task ended, or
  held by a live run, does nothing. See "Recovery" in `Sake.Tasks` for
  what happens to a run that dies.
  """

  @doc """
  Gets the job to a process that calls `Sake.Tasks.run/1`. `opts` are the
  runner's, from `tasks: [runner: {module, opts}]`. `{:error, reason}`
  fails the task at once.
  """
  @callback start(job :: Sake.Tasks.Job.t(), opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  The client cancelled the task: stop its run where the runner can (cancel
  a queued job, say). Sake marks the task cancelled and stops a run on the
  receiving node itself; a run elsewhere sees the cancellation when it
  next asks for input or checks `Sake.Tasks.cancelled?/1`.
  """
  @callback cancel(task_id :: String.t(), opts :: keyword()) :: :ok

  @doc """
  Whether the runner runs a job again itself when the process running it
  dies (a durable queue's retries do). Sake's leases then leave its tasks
  to it, until they expire. `false` by default.
  """
  @callback recovers?() :: boolean()

  @optional_callbacks cancel: 2, recovers?: 0

  @doc false
  def config do
    case Sake.Tasks.config().runner do
      {module, opts} -> {module, opts}
      module when is_atom(module) -> {module, []}
    end
  end

  @doc false
  def recovers? do
    {module, _opts} = config()
    function_exported?(module, :recovers?, 0) and module.recovers?()
  end

  @doc false
  def cancel(task_id) do
    {module, opts} = config()
    if function_exported?(module, :cancel, 2), do: module.cancel(task_id, opts), else: :ok
  end
end

defmodule Sake.Tasks.Runner.Local do
  @moduledoc """
  The default `Sake.Tasks.Runner`: each task runs at once, in a process of
  the node that started it, under `Sake.Tasks`'s supervisor. Nothing to
  add, no queue, no database.

  The run holds a lease on the task while it lives. If the node goes
  away, the lease lapses, and any node's reaper applies the tool's
  `recovery:` (see "Recovery" in `Sake.Tasks`): the task fails, or, for a
  tool that opted in, runs again here, on the reaping node. Only with a
  store every node shares (`Sake.Tasks.Store.Ecto`) can another node see
  the orphan; with the ETS store, the task goes with the node.
  """
  @behaviour Sake.Tasks.Runner

  @impl true
  def start(job, _opts) do
    Sake.Tasks.Worker.start_local(job)
    :ok
  end
end
