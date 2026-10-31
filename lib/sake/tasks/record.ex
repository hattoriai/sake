defmodule Sake.Tasks.Record do
  @moduledoc """
  A task as a `Sake.Tasks.Store` keeps it.

  `principal` binds the task to whoever created it, and through which
  server, client and resource (a digest, see `Sake.Tasks`); `scopes` are
  the scopes its tool required, which every later access needs too;
  `input_requests` are the requests still waiting for the client's answer,
  and `answers` every answer delivered so far, by key; `result` is the
  tool's result once `completed`, and `error` the JSON-RPC error once
  `failed`. Times are UTC, to the millisecond.

  The execution fields: `job` is what a run needs to execute the tool
  again (`Sake.Tasks.Job`), `attempt` which run this is, `lease_owner`
  and `lease_until` the run that holds the task and until when (a run
  renews its lease while it lives; a lapsed one is an orphan, see
  `Sake.Tasks`), and `handle` the external job a tool handed the task
  to, if any.
  """

  @type status :: :working | :input_required | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          principal: String.t() | nil,
          tool: String.t(),
          scopes: [String.t()],
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
          expires_at: DateTime.t(),
          job: Sake.Tasks.Job.t() | nil,
          attempt: pos_integer(),
          lease_owner: String.t() | nil,
          lease_until: DateTime.t() | nil,
          handle: String.t() | nil
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
    :job,
    :lease_owner,
    :lease_until,
    :handle,
    attempt: 1,
    status: :working,
    scopes: [],
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
  Whether the task is an orphan at `now`: live, held by a run whose lease
  lapsed, and not handed to an external job.
  """
  @spec orphan?(t(), DateTime.t()) :: boolean()
  def orphan?(%__MODULE__{lease_until: %DateTime{} = until, handle: nil} = r, now) do
    not terminal?(r) and not expired?(r, now) and DateTime.compare(until, now) == :lt
  end

  def orphan?(_record, _now), do: false

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
