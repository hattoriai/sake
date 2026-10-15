defmodule Sake.Tasks.Worker do
  @moduledoc false
  # Runs a task's tool in the background, under `Sake.Tasks.Supervisor`,
  # and records how it ended. A worker (and any process it starts to ask
  # several things at once, see `Sake.Input`) registers under the task ID
  # in `Sake.Tasks.Registry`, so a `tasks/update` or `tasks/cancel` on
  # this node reaches it at once; on any other node it learns of them by
  # polling the store.

  require Logger

  alias Sake.Server.Results
  alias Sake.Tasks
  alias Sake.Tasks.Record

  @failure %{"code" => -32_603, "message" => "The tool failed."}

  @spec start(Sake.Tool.Spec.t(), map(), Sake.Context.t(), Record.t()) :: :ok
  def start(spec, args, ctx, record) do
    ctx = %{
      ctx
      | task: record.id,
        transport: nil,
        progress: &progress(ctx.server, record.id, &1, &2)
    }

    {:ok, pid} =
      Task.Supervisor.start_child(Tasks.Supervisor, fn -> run(spec, args, ctx) end,
        restart: :temporary
      )

    # A task outlives its request but not its time-to-live.
    {:ok, _} = :timer.kill_after(record.ttl_ms, pid)
    :ok
  end

  defp run(spec, args, ctx) do
    # Trapping exits turns a crash in a process the tool started (a linked
    # `Task`) into an error the tool sees, rather than a silent death that
    # would leave the task working until it expires.
    Process.flag(:trap_exit, true)
    {:ok, _} = Registry.register(Tasks.Registry, ctx.task, :worker)
    meta = %{task_id: ctx.task, tool: spec.name, server: ctx.server}

    :telemetry.span([:sake, :task], meta, fn ->
      status = if Tasks.cancelled?(ctx), do: :cancelled, else: execute_and_finish(spec, args, ctx)
      {status, Map.put(meta, :status, status)}
    end)
  end

  defp execute_and_finish(spec, args, ctx) do
    outcome = execute(spec, args, ctx)

    case Tasks.update(ctx.server, ctx.task, &finish(&1, outcome)) do
      {:ok, record} -> record.status
      :error -> :expired
    end
  end

  defp execute(spec, args, ctx) do
    {:completed, Results.tool(spec.module.execute(args, ctx), spec, ctx)}
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

  # A task that already ended (a cancellation won the race) stays as it is.
  defp finish(record, outcome),
    do: if(Record.terminal?(record), do: record, else: ended(record, outcome))

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
