defmodule Sake.Tasks.Store do
  @moduledoc """
  Where tasks live between the request that creates them and the requests
  that poll, answer or cancel them. Implemented by `Sake.Tasks.Store.ETS`
  (one node) and `Sake.Tasks.Store.Ecto` (any number of nodes).
  """
  alias Sake.Tasks.Record

  @type state :: term()

  @callback init(keyword()) :: state()

  @doc """
  Stores a new task, unless its owner (`principal`) already has `max` live
  tasks: neither ended nor expired at the new task's `created_at`. The
  count and the insert are atomic, so concurrent inserts for one owner
  never get past `max` together. Once this returns `:ok`, `get/2` on any
  node finds the task.
  """
  @callback insert(state(), Record.t(), max :: pos_integer() | :infinity) :: :ok | :full

  @callback get(state(), id :: String.t()) :: {:ok, Record.t()} | :error

  @doc """
  Applies `fun` to the task atomically: no other update of the same task
  runs between the read and the write. Returns the task before and after.
  """
  @callback update(state(), id :: String.t(), (Record.t() -> Record.t())) ::
              {:ok, before :: Record.t(), after_update :: Record.t()} | :error

  @doc "Deletes the tasks that expired by `now`."
  @callback prune(state(), now :: DateTime.t()) :: :ok
end
