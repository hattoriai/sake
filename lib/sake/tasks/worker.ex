defmodule Sake.Tasks.Worker do
  @moduledoc false
  # Runs a task's tool in the background, under `Sake.Tasks.Supervisor`,
  # and records how it ended. A worker (and any process it starts to ask
  # several things at once, see `Sake.Input`) registers under the task ID
  # in `Sake.Tasks.Registry`, so a `tasks/update` or `tasks/cancel` on
  # this node reaches it at once; on any other node it learns of them by
  # polling the store.

  require Logger

  alias Sake.Server.{Middleware, Mount, Results}
  alias Sake.{Tasks, Trace}
  alias Sake.Tasks.Record

  @failure %{"code" => -32_603, "message" => "The tool failed."}

  @doc """
  Starts the task's run. `follow`, when given, runs instead of the tool's
  `execute/2`: a proxied tool's upstream task, followed to its end (see
  `Sake.Proxy.Forward.follow/3`).
  """
  @spec start(
          Sake.Tool.Spec.t(),
          map(),
          Sake.Context.t(),
          Record.t(),
          (Sake.Context.t() -> term()) | nil
        ) :: :ok
  def start(spec, args, ctx, record, follow \\ nil) do
    ctx = %{
      ctx
      | task: record.id,
        transport: nil,
        progress: &progress(ctx.server, record.id, &1, &2)
    }

    # Bound here, in the `tools/call` request, so the run's span is the
    # child of the request's (see `Sake.Trace.task/3`).
    caller = self()
    ref = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(
        Tasks.Supervisor,
        Trace.bind(fn -> run(spec, args, ctx, follow, {caller, ref}) end),
        restart: :temporary
      )

    # The worker is registered before the task is handed to the client:
    # a `tasks/cancel` or `tasks/update` that follows at once reaches it.
    monitor = Process.monitor(pid)

    receive do
      {^ref, :registered} -> :ok
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end

    Process.demonitor(monitor, [:flush])

    # A task outlives its request but not its time-to-live.
    {:ok, _} = :timer.kill_after(record.ttl_ms, pid)
    :ok
  end

  defp run(spec, args, ctx, follow, {caller, ref}) do
    # Trapping exits turns a crash in a process the tool started (a linked
    # `Task`) into an error the tool sees, rather than a silent death that
    # would leave the task working until it expires.
    Process.flag(:trap_exit, true)
    {:ok, _} = Registry.register(Tasks.Registry, ctx.task, :worker)
    send(caller, {ref, :registered})
    meta = %{task_id: ctx.task, tool: spec.name, server: ctx.server}

    Trace.task(spec.name, ctx.task, fn ->
      :telemetry.span([:sake, :task], meta, fn -> status(spec, args, ctx, follow, meta) end)
    end)
  end

  defp status(spec, args, ctx, follow, meta) do
    status =
      if Tasks.cancelled?(ctx), do: :cancelled, else: execute_and_finish(spec, args, ctx, follow)

    {status, Map.put(meta, :status, status)}
  end

  defp execute_and_finish(spec, args, ctx, follow) do
    outcome = execute(spec, args, ctx, follow)
    _ = Trace.outcome(trace_outcome(outcome))

    case Tasks.update(ctx.server, ctx.task, &finish(&1, outcome)) do
      {:ok, record} -> record.status
      :error -> :expired
    end
  end

  defp execute(spec, args, ctx, nil) do
    case spec.module.execute(args, Mount.component_ctx(spec, ctx)) do
      {:error, {:missing_capability, caps}} ->
        {_, code, message, data} = Sake.Server.Dispatch.missing_capability(caps)
        {:failed, %{"code" => code, "message" => message, "data" => data}}

      result ->
        result
        |> Results.tool(spec, ctx)
        |> Mount.outer_result(spec, ctx)
        |> after_call(spec, args, ctx)
    end
  rescue
    exception ->
      Logger.error(
        "task #{ctx.task} (tool #{spec.name}) failed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:failed, @failure}
  catch
    kind, reason ->
      Logger.error(
        "task #{ctx.task} (tool #{spec.name}) failed: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:failed, @failure}
  end

  # A followed upstream task's result is already a wire result.
  defp execute(spec, args, ctx, follow) do
    case follow.(ctx) do
      {:ok, result} -> result |> Mount.outer_result(spec, ctx) |> after_call(spec, args, ctx)
      {:failed, error} -> {:failed, error}
      :cancelled -> :cancelled
    end
  rescue
    exception ->
      Logger.error(
        "task #{ctx.task} (tool #{spec.name}) failed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
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
  defp trace_outcome(:cancelled), do: {:error, %{"code" => -32_603, "message" => "Cancelled"}}

  # A task that already ended (a cancellation won the race) stays as it is.
  defp finish(record, outcome),
    do: if(Record.terminal?(record), do: record, else: ended(record, outcome))

  defp ended(record, :cancelled), do: %{record | status: :cancelled, input_requests: %{}}

  defp ended(record, {:completed, result}),
    do: %{record | status: :completed, result: result, input_requests: %{}, status_message: nil}

  defp ended(record, {:failed, error}) do
    %{
      record
      | status: :failed,
        error: error,
        input_requests: %{},
        status_message: error["message"]
    }
  end

  defp progress(server, id, current, {total, message}) do
    text = message || if(total, do: "#{current}/#{total}", else: "#{current}")

    _ =
      Tasks.update(server, id, fn record ->
        if Record.terminal?(record), do: record, else: %{record | status_message: text}
      end)

    :ok
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
