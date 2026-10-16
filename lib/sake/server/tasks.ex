defmodule Sake.Server.Tasks do
  @moduledoc false
  # The methods of the tasks extension (`io.modelcontextprotocol/tasks`,
  # modern era only): the `CreateTaskResult` a task tool answers with, and
  # `tasks/get`, `tasks/update` and `tasks/cancel`. See `Sake.Tasks`.

  alias Sake.{Context, JSONRPC}
  alias Sake.Tasks
  alias Sake.Tasks.{Record, Worker}

  @doc false
  # Whether any tool of the server can run as a task, here.
  # A server with a proxy may make a task of any proxied call: the
  # upstream decides.
  def supported?(server) do
    Tasks.running?() and
      (Sake.Server.dynamic?(server) or Enum.any?(server.__sake__(:tools), & &1.task))
  end

  @doc false
  # Whether the request's client declared the extension. Tasks are a
  # modern-era extension: a legacy session's capabilities never count.
  def declared?(%Context{era: :modern, client_capabilities: %{"extensions" => %{} = ext}}),
    do: is_map(ext[Tasks.extension()])

  def declared?(_ctx), do: false

  @doc false
  def missing_capability,
    do: Sake.Server.Dispatch.missing_capability(%{"extensions" => %{Tasks.extension() => %{}}})

  @doc false
  # Stores the task (so that a `tasks/get` anywhere finds it) before the
  # worker starts, and before the client hears of it. `follow` runs a
  # proxied upstream task instead of the tool (see `Sake.Tasks.Worker`).
  def start(spec, args, ctx, follow \\ nil) do
    record = Tasks.create(ctx, spec.name)
    :ok = Worker.start(spec, args, ctx, record, follow)
    {:ok, record |> Record.to_wire() |> Map.put("resultType", "task")}
  end

  @doc false
  def get(server, params, ctx) do
    with :ok <- usable(server, ctx),
         {:ok, record} <- find(params, ctx) do
      {:ok, Record.to_wire(record)}
    end
  end

  @doc false
  def update(server, params, ctx) do
    with :ok <- usable(server, ctx),
         {:ok, responses} <- responses(params),
         {:ok, record} <- find(params, ctx) do
      _ = Tasks.update(server, record.id, &answer(&1, responses))
      :ok = Tasks.wake(record.id)
      {:ok, %{}}
    end
  end

  @doc false
  # Cooperative, as the extension has it: the task is marked cancelled at
  # once (unless it already ended, which is acknowledged the same way) and
  # its process stopped when it runs on this node.
  def cancel(server, params, ctx) do
    with :ok <- usable(server, ctx),
         {:ok, record} <- find(params, ctx) do
      _ = Tasks.update(server, record.id, &cancelled/1)
      :ok = Tasks.stop(record.id)
      {:ok, %{}}
    end
  end

  defp cancelled(record) do
    if Record.terminal?(record),
      do: record,
      else: %{record | status: :cancelled, input_requests: %{}}
  end

  @doc false
  # The task IDs a `subscriptions/listen` request may follow: the caller's
  # own, live tasks.
  def visible(ids, ctx) when is_list(ids) do
    if Tasks.running?(),
      do: Enum.filter(ids, &match?({:ok, _}, find(%{"taskId" => &1}, ctx))),
      else: []
  end

  def visible(_ids, _ctx), do: []

  defp usable(server, ctx) do
    cond do
      not supported?(server) -> {:error, JSONRPC.code(:method_not_found), "Method not found"}
      not declared?(ctx) -> missing_capability()
      true -> :ok
    end
  end

  # A task of another principal is as unknown as a task that never existed.
  defp find(%{"taskId" => id}, ctx) when is_binary(id) do
    case Tasks.fetch(id) do
      {:ok, %Record{principal: principal} = record} ->
        if principal == Tasks.principal(ctx), do: {:ok, record}, else: not_found()

      :error ->
        not_found()
    end
  end

  defp find(_params, _ctx), do: {:error, JSONRPC.code(:invalid_params), "Missing taskId"}

  defp not_found,
    do: {:error, JSONRPC.code(:invalid_params), "Failed to retrieve task: Task not found"}

  defp responses(%{"inputResponses" => %{} = responses}), do: {:ok, responses}

  defp responses(_params),
    do: {:error, JSONRPC.code(:invalid_params), "tasks/update needs inputResponses"}

  # Only answers to outstanding requests count: a key never asked, or
  # already answered, is ignored. The task works again once nothing is
  # outstanding.
  defp answer(record, responses) do
    answered = Map.take(responses, Map.keys(record.input_requests))

    if Record.terminal?(record) or answered == %{} do
      record
    else
      pending = Map.drop(record.input_requests, Map.keys(answered))

      %{
        record
        | answers: Map.merge(record.answers, answered),
          input_requests: pending,
          status: if(pending == %{}, do: :working, else: :input_required)
      }
    end
  end
end
