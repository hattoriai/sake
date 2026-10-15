defmodule Sake.Tasks.Store.ETS do
  @moduledoc """
  The default task store: in memory, on one node. Tasks are lost on
  restart, and a task created on one node is unknown to the others; use
  `Sake.Tasks.Store.Ecto` when the endpoint runs on several nodes.
  """
  @behaviour Sake.Tasks.Store

  alias Sake.Tasks.Record

  @table __MODULE__.Tasks

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [nil]}}

  # An `Agent`, not `use GenServer`, as in `Sake.Auth.Store.ETS`. Reads go
  # to the table directly; writes go through the Agent, so an update's read
  # and write are never interleaved with another update of the same task.
  def start_link(_) do
    Agent.start_link(
      fn ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        nil
      end,
      name: __MODULE__
    )
  end

  @impl true
  def init(_opts), do: nil

  @impl true
  def insert(_s, %Record{} = record) do
    true = :ets.insert(@table, {record.id, record})
    :ok
  end

  @impl true
  def get(_s, id) do
    case :ets.lookup(@table, id) do
      [{^id, record}] -> {:ok, record}
      [] -> :error
    end
  end

  @impl true
  def update(_s, id, fun) do
    Agent.get_and_update(__MODULE__, fn nil ->
      case :ets.lookup(@table, id) do
        [{^id, before}] ->
          updated = fun.(before)
          true = :ets.insert(@table, {id, updated})
          {{:ok, before, updated}, nil}

        [] ->
          {:error, nil}
      end
    end)
  end

  @impl true
  def prune(_s, now) do
    Agent.get(__MODULE__, fn nil ->
      for {id, record} <- :ets.tab2list(@table),
          Record.expired?(record, now),
          do: :ets.delete(@table, id)
    end)

    :ok
  end
end
