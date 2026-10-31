defmodule Sake.Tasks.Worker do
  @moduledoc false
  # Runs a task's tool and records how it ended.
  #
  # A run first claims the task: it takes the task's lease under a token
  # of its own, if the task is live and its lease is free, lapsed, or
  # reserved for the job's `run_id` (the run the job was dispatched for).
  # It renews the lease while it lives (a heartbeat process), and records
  # the outcome only while it still holds it. A second delivery of a job,
  # or a run that outlived its lease and was replaced, so changes nothing.
  #
  # A run (and any process it starts to ask several things at once, see
  # `Sake.Input`) registers under the task ID in `Sake.Tasks.Registry`, so
  # a `tasks/update` or `tasks/cancel` on its node reaches it at once; on
  # any other node it learns of them by polling the store.

  require Logger

  alias Sake.Server.{Middleware, Mount, Results}
  alias Sake.{Tasks, Trace}
  alias Sake.Tasks.{Job, Record, Runner}

  @failure %{"code" => -32_603, "message" => "The tool failed."}

  # ---- starting

  @doc """
  Starts the task the request just created: records its job and reserves
  its lease for the job's run, then hands the job to the configured
  runner. `follow`, when given, runs instead of the tool's `execute/2`
  (a proxied tool's upstream task, see `Sake.Proxy.Forward.follow/3`):
  a function cannot leave this node, so such a task always runs here.
  """
  @spec start(Sake.Tool.Spec.t(), map(), Sake.Context.t(), Record.t(), function() | nil) :: :ok
  def start(spec, args, ctx, record, follow \\ nil) do
    job = Job.new(record.id, spec, args, ctx)
    lease = lease_until()

    {:ok, _} =
      Tasks.update(ctx.server, record.id, fn r ->
        %{r | job: job, lease_owner: job.run_id, lease_until: lease}
      end)

    if follow do
      start_local(job, follow)
    else
      dispatch(job)
    end

    :ok
  end

  # A runner that cannot take the job fails the task at once, rather than
  # leave it working until its lease lapses.
  defp dispatch(job) do
    {module, opts} = Runner.config()

    case module.start(job, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "task #{job.task_id}: #{inspect(module)} could not start it: #{inspect(reason)}"
        )

        _ = Tasks.update(job.server, job.task_id, &finish(&1, {:failed, @failure}, :any))
        :ok
    end
  end

  @doc """
  Runs the job in a process of this node, under `Sake.Tasks.Supervisor`,
  registered before this returns: a `tasks/cancel` or `tasks/update` that
  follows at once reaches it. Bound to the caller's trace (see
  `Sake.Trace.task/3`), and killed when the task expires.
  """
  @spec start_local(Job.t(), function() | nil) :: :ok
  def start_local(job, follow \\ nil) do
    caller = self()
    ref = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(
        Tasks.Supervisor,
        Trace.bind(fn -> run(job, follow, {caller, ref}) end),
        restart: :temporary
      )

    monitor = Process.monitor(pid)

    receive do
      {^ref, :registered} -> :ok
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end

    Process.demonitor(monitor, [:flush])

    case Tasks.fetch(job.task_id) do
      {:ok, record} ->
        left = max(DateTime.diff(record.expires_at, Tasks.now(), :millisecond), 0)
        {:ok, _} = :timer.kill_after(left, pid)

      :error ->
        :ok
    end

    :ok
  end

  # ---- running

  @doc "Claims the task and runs its tool; see `Sake.Tasks.run/1`."
  @spec run(Job.t(), function() | nil, {pid(), reference()} | nil) ::
          Record.status() | :expired | {:skipped, atom()}
  def run(%Job{} = job, follow \\ nil, ack \\ nil) do
    # Trapping exits turns a crash in a process the tool started (a linked
    # `Task`) into an error the tool sees, rather than a silent death that
    # would leave the task working until its lease lapses.
    Process.flag(:trap_exit, true)
    {:ok, _} = Registry.register(Tasks.Registry, job.task_id, :worker)

    result =
      case claim(job) do
        {:ok, token} -> claimed(job, token, follow, ack)
        skipped -> ack!(ack) && skipped
      end

    :ok = Registry.unregister_match(Tasks.Registry, job.task_id, :worker)
    result
  end

  defp ack!(nil), do: true
  defp ack!({caller, ref}), do: send(caller, {ref, :registered})

  defp claimed(job, token, follow, ack) do
    heartbeat = heartbeat(job, token)
    ack!(ack)

    ctx = %{
      Job.context(job)
      | progress: &progress(job.server, job.task_id, &1, &2),
        transport: nil
    }

    spec = spec(job)
    meta = %{task_id: job.task_id, tool: job.tool, server: job.server, attempt: job.attempt}

    try do
      Trace.task(job.tool, job.task_id, fn ->
        :telemetry.span([:sake, :task], meta, fn ->
          status = status(spec, job.args, ctx, follow, token)
          {status, Map.put(meta, :status, status)}
        end)
      end)
    after
      Process.unlink(heartbeat)
      Process.exit(heartbeat, :kill)
    end
  end

  # The tool's spec as the job's server has it now; a proxied tool, known
  # only at runtime, through the job's context.
  defp spec(job) do
    case Sake.Server.tool(job.server, job.tool, Job.context(job)) do
      {:ok, spec} -> spec
      :error -> nil
    end
  end

  # The task is claimed when its lease is ours: free, lapsed, or reserved
  # for this job's run.
  @spec claim(Job.t()) :: {:ok, String.t()} | {:skipped, atom()}
  defp claim(job) do
    token = Job.run_id()
    now = Tasks.now()
    until = lease_until(now)

    case Tasks.update(job.server, job.task_id, &claim_record(&1, job, token, now, until)) do
      {:ok, %Record{lease_owner: ^token}} -> {:ok, token}
      {:ok, %Record{} = record} -> {:skipped, skipped_reason(record)}
      :error -> {:skipped, :expired}
    end
  end

  defp claim_record(record, job, token, now, until) do
    free? =
      record.lease_owner in [nil, job.run_id] or
        (record.lease_until != nil and DateTime.compare(record.lease_until, now) == :lt)

    if not Record.terminal?(record) and record.handle == nil and free?,
      do: %{record | lease_owner: token, lease_until: until, attempt: job.attempt},
      else: record
  end

  defp skipped_reason(record) do
    cond do
      Record.terminal?(record) -> :ended
      record.handle != nil -> :external
      true -> :running
    end
  end

  # Renews the lease while the run lives, as long as it still holds it.
  defp heartbeat(job, token) do
    every = max(div(Tasks.config().lease, 3), 10)
    spawn_link(fn -> beat(job, token, every) end)
  end

  defp beat(job, token, every) do
    Process.sleep(every)
    until = lease_until()

    renewed =
      Tasks.update(job.server, job.task_id, fn r ->
        if r.lease_owner == token and not Record.terminal?(r),
          do: %{r | lease_until: until},
          else: r
      end)

    case renewed do
      {:ok, %Record{lease_owner: ^token} = r} ->
        if Record.terminal?(r), do: :ok, else: beat(job, token, every)

      _ ->
        :ok
    end
  end

  defp lease_until(now \\ Tasks.now()), do: DateTime.add(now, Tasks.config().lease, :millisecond)

  defp status(nil, _args, ctx, _follow, token) do
    Logger.error("task #{ctx.task}: the server no longer has its tool")
    record_outcome(ctx, {:failed, @failure}, token)
  end

  defp status(spec, args, ctx, follow, token) do
    if Tasks.cancelled?(ctx) do
      :cancelled
    else
      outcome = execute(spec, args, ctx, follow)
      _ = Trace.outcome(trace_outcome(outcome))
      record_outcome(ctx, outcome, token)
    end
  end

  defp record_outcome(ctx, outcome, token) do
    case Tasks.update(ctx.server, ctx.task, &finish(&1, outcome, token)) do
      {:ok, %Record{handle: handle, status: :working}} when handle != nil -> :external
      {:ok, record} -> record.status
      :error -> :expired
    end
  end

  defp execute(spec, args, ctx, nil) do
    case spec.module.execute(args, Mount.component_ctx(spec, ctx)) do
      {:external, handle} when is_binary(handle) ->
        {:external, handle}

      {:error, {:missing_capability, caps}} ->
        {_, code, message, data} = Sake.Server.Dispatch.missing_capability(caps)
        {:failed, %{"code" => code, "message" => message, "data" => data}}

      result ->
        outcome(result, spec, args, ctx)
    end
  rescue
    exception -> failed(ctx, spec, :error, exception, __STACKTRACE__)
  catch
    kind, reason -> failed(ctx, spec, kind, reason, __STACKTRACE__)
  end

  # A followed upstream task's result is already a wire result.
  defp execute(spec, args, ctx, follow) do
    case follow.(ctx) do
      {:ok, result} -> result |> Mount.outer_result(spec, ctx) |> after_call(spec, args, ctx)
      {:failed, error} -> {:failed, error}
      :cancelled -> :cancelled
    end
  rescue
    exception -> failed(ctx, spec, :error, exception, __STACKTRACE__)
  end

  defp outcome(result, spec, args, ctx) do
    result
    |> Results.tool(spec, ctx)
    |> Mount.outer_result(spec, ctx)
    |> after_call(spec, args, ctx)
  end

  defp failed(ctx, spec, kind, reason, stacktrace) do
    Logger.error(
      "task #{ctx.task} (tool #{spec.name}) failed: " <>
        Exception.format(kind, reason, stacktrace)
    )

    {:failed, @failure}
  end

  # The `tools/call` that started the task ran `:before_call`; its
  # `:after_call` runs here, with that request's assigns, once the tool has
  # a result. A halt fails the task with the error the call would have
  # answered with (a tool error stays a result).
  defp after_call(result, spec, args, ctx) do
    payload = %{tool: spec, arguments: args, result: result}

    case Middleware.after_result(:after_call, payload, ctx) do
      {:ok, result} -> {:completed, result}
      {:halt, reason} -> reason |> Middleware.refusal(%{"name" => spec.name}, ctx) |> refused()
    end
  end

  defp refused({:ok, result}), do: {:completed, result}
  defp refused({:forbidden, scopes}), do: {:failed, Sake.Plug.Stream.forbidden(scopes)}

  defp refused({:insufficient_user_authentication, _refusal}),
    do: {:failed, Sake.Plug.Stream.insufficient_user_authentication()}

  defp refused({:error, code, message}), do: {:failed, %{"code" => code, "message" => message}}

  defp refused({:error, code, message, data}),
    do: {:failed, %{"code" => code, "message" => message, "data" => data}}

  defp trace_outcome({:completed, result}), do: {:reply, result}
  defp trace_outcome({:failed, error}), do: {:error, error}
  defp trace_outcome({:external, _handle}), do: {:reply, %{}}
  defp trace_outcome(:cancelled), do: {:error, %{"code" => -32_603, "message" => "Cancelled"}}

  # A task that already ended (a cancellation won the race), or that
  # another run holds now, stays as it is. `:any` records the outcome
  # whoever holds the task (a runner that failed to start it).
  defp finish(record, outcome, token) do
    cond do
      Record.terminal?(record) -> record
      token != :any and record.lease_owner != token -> record
      true -> ended(record, outcome)
    end
  end

  # Handed to an external job: the task keeps working, with no lease to
  # lapse, until the job reports (`complete/3`, `fail/3`) or the task
  # expires.
  defp ended(record, {:external, handle}),
    do: %{record | handle: handle, lease_owner: nil, lease_until: nil}

  defp ended(record, outcome), do: record |> terminal(outcome) |> release()

  defp terminal(record, :cancelled), do: %{record | status: :cancelled, input_requests: %{}}

  defp terminal(record, {:completed, result}),
    do: %{record | status: :completed, result: result, input_requests: %{}, status_message: nil}

  defp terminal(record, {:failed, error}) do
    %{
      record
      | status: :failed,
        error: error,
        input_requests: %{},
        status_message: error["message"]
    }
  end

  defp release(record), do: %{record | lease_owner: nil, lease_until: nil}

  defp progress(server, id, current, {total, message}) do
    text = message || if(total, do: "#{current}/#{total}", else: "#{current}")

    _ =
      Tasks.update(server, id, fn record ->
        if Record.terminal?(record), do: record, else: %{record | status_message: text}
      end)

    :ok
  end

  # ---- an external job's report

  @doc """
  The external job `handle` reports the task's result (`execute/2`'s
  return forms) or its failure; see `Sake.Tasks.complete/3`.
  """
  @spec report(String.t(), String.t(), term()) :: :ok | :error
  def report(task_id, handle, report) do
    with {:ok, %Record{handle: ^handle, job: %Job{} = job} = record} <- Tasks.fetch(task_id),
         false <- Record.terminal?(record) do
      ctx = Job.context(job)
      outcome = report_outcome(report, spec(job), job, ctx)

      case Tasks.update(job.server, task_id, &external_finish(&1, handle, outcome)) do
        {:ok, %Record{status: status}} when status in [:completed, :failed] -> :ok
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp report_outcome({:failed, message}, _spec, _job, _ctx),
    do: {:failed, %{"code" => -32_603, "message" => message}}

  defp report_outcome(_result, nil, _job, _ctx), do: {:failed, @failure}
  defp report_outcome(result, spec, job, ctx), do: outcome(result, spec, job.args, ctx)

  defp external_finish(record, handle, outcome) do
    if record.handle == handle and not Record.terminal?(record),
      do: ended(record, outcome),
      else: record
  end

  @doc "The external job `handle`'s progress; see `Sake.Tasks.progress/5`."
  @spec external_progress(String.t(), String.t(), number(), {number() | nil, String.t() | nil}) ::
          :ok | :error
  def external_progress(task_id, handle, current, total_and_message) do
    case Tasks.fetch(task_id) do
      {:ok, %Record{handle: ^handle, job: %Job{server: server}}} ->
        progress(server, task_id, current, total_and_message)

      _ ->
        :error
    end
  end

  # ---- recovery: an orphan found by the reaper (`Sake.Tasks.Reaper`)

  @doc """
  Recovers an orphan: runs it again when its tool opted in and has runs
  left, and fails it otherwise. Several nodes may find the same orphan:
  the store's atomic update lets one of them act.
  """
  @spec recover(Record.t()) :: :retried | :failed | :skipped
  def recover(%Record{job: job} = record) do
    now = Tasks.now()
    token = Job.run_id()
    retry? = retry?(record)

    update = fn r ->
      cond do
        not Record.orphan?(r, now) -> r
        retry? -> %{r | lease_owner: token, lease_until: lease_until(now), attempt: r.attempt + 1}
        true -> r |> terminal({:failed, lost(r)}) |> release()
      end
    end

    case Tasks.update(server(record), record.id, update) do
      {:ok, %Record{lease_owner: ^token, attempt: attempt}} when retry? ->
        Logger.warning(
          "task #{record.id} (tool #{record.tool}) lost its run: running it again (attempt #{attempt})"
        )

        dispatch(%{job | run_id: token, attempt: attempt})
        :retried

      {:ok, %Record{status: :failed, error: %{"data" => %{"reason" => "worker_lost"}}}} ->
        Logger.warning("task #{record.id} (tool #{record.tool}) lost its run: failed")
        :failed

      _ ->
        :skipped
    end
  end

  defp retry?(%Record{job: %Job{} = job, attempt: attempt}) do
    case Sake.Server.tool(job.server, job.tool) do
      {:ok, %{task_recovery: {:retry, max}}} -> attempt < max
      _ -> false
    end
  end

  defp retry?(_record), do: false

  defp server(%Record{job: %Job{server: server}}), do: server
  defp server(_record), do: nil

  defp lost(record) do
    %{
      "code" => -32_603,
      "message" => "The task's worker stopped before the task ended.",
      "data" => %{"reason" => "worker_lost", "attempts" => record.attempt}
    }
  end

  # ---- input: called by `Sake.Server.Ask` from inside the task

  @spec ask(Sake.Context.t(), String.t(), map()) :: {:ok, term()} | {:error, :cancelled}
  def ask(ctx, key, request) do
    # Registered before the request is stored, so a wake for the answer
    # cannot slip in between and be missed.
    {:ok, _} = Registry.register(Tasks.Registry, ctx.task, :waiter)

    answer =
      case Tasks.update(ctx.server, ctx.task, &pending(&1, key, request)) do
        {:ok, record} -> await(ctx, key, record)
        :error -> {:error, :cancelled}
      end

    :ok = Registry.unregister_match(Tasks.Registry, ctx.task, :waiter)
    answer
  end

  # A key answered before (by an earlier run of the task, too) is answered
  # at once: a run that starts again asks again, and gets what the client
  # already said.
  defp pending(record, key, request) do
    if Record.terminal?(record) or Map.has_key?(record.answers, key),
      do: record,
      else: %{
        record
        | status: :input_required,
          input_requests: Map.put(record.input_requests, key, request)
      }
  end

  defp await(ctx, key, record) do
    cond do
      Map.has_key?(record.answers, key) -> {:ok, record.answers[key]}
      Record.terminal?(record) -> {:error, :cancelled}
      true -> wait(ctx, key)
    end
  end

  defp wait(ctx, key) do
    id = ctx.task

    receive do
      {:sake_task_wake, ^id} -> :ok
    after
      Tasks.config().poll_interval -> :ok
    end

    case Tasks.fetch(id) do
      {:ok, record} -> await(ctx, key, record)
      :error -> {:error, :cancelled}
    end
  end
end
