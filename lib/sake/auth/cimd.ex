defmodule Sake.Auth.CIMD.Cache do
  @moduledoc false
  # An ETS-backed cache with per-entry expiry, keyed by whatever the caller
  # chooses.
  use GenServer
  @table __MODULE__
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [nil]}}

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.system_time(:second) < expires_at, do: {:ok, value}, else: :error

      [] ->
        :error
    end
  end

  def put(key, value, ttl) do
    :ets.insert(@table, {key, value, System.system_time(:second) + ttl})
    :ok
  end
end
