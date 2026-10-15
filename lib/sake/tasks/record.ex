defmodule Sake.Tasks.Record do
  @moduledoc """
  A task as a `Sake.Tasks.Store` keeps it.

  `principal` binds the task to whoever created it (see `Sake.Tasks`);
  `input_requests` are the requests still waiting for the client's answer,
  and `answers` every answer delivered so far, by key; `result` is the
  tool's result once `completed`, and `error` the JSON-RPC error once
  `failed`. Times are UTC, to the millisecond.
  """

  @type status :: :working | :input_required | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          principal: String.t() | nil,
          tool: String.t(),
          status: status(),
          status_message: String.t() | nil,
          input_requests: map(),
          answers: map(),
          result: map() | nil,
          error: map() | nil,
          ttl_ms: pos_integer(),
          poll_interval_ms: pos_integer(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  defstruct [
    :id,
    :principal,
    :tool,
    :status_message,
    :result,
    :error,
    :ttl_ms,
    :poll_interval_ms,
    :created_at,
    :updated_at,
    :expires_at,
    status: :working,
    input_requests: %{},
    answers: %{}
  ]

  @doc "Whether the task has ended: completed, failed or cancelled."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :failed, :cancelled]

  @doc "Whether the task outlived its time-to-live by `now`."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: at}, now), do: DateTime.compare(at, now) != :gt

  @doc """
  The task on the wire: a `DetailedTask`, with `inputRequests` while it
  waits for input, `result` once completed and `error` once failed.
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = r) do
    %{
      "taskId" => r.id,
      "status" => Atom.to_string(r.status),
      "createdAt" => timestamp(r.created_at),
      "lastUpdatedAt" => timestamp(r.updated_at),
      "ttlMs" => r.ttl_ms,
      "pollIntervalMs" => r.poll_interval_ms
    }
    |> put_some("statusMessage", r.status_message)
    |> detail(r)
  end

  defp detail(task, %{status: :input_required} = r),
    do: Map.put(task, "inputRequests", r.input_requests)

  defp detail(task, %{status: :completed} = r), do: Map.put(task, "result", r.result)
  defp detail(task, %{status: :failed} = r), do: Map.put(task, "error", r.error)
  defp detail(task, _r), do: task

  defp timestamp(at), do: at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)
end
