defmodule Sake.Auth.Replay do
  @moduledoc false
  # The JWT IDs already seen, so a client assertion or a JWT grant is
  # accepted once (RFC 7523 §3, and the ID-JAG's `jti`). Each is kept
  # until its token expires (plus the clock leeway), keyed by its issuer:
  # two issuers may well pick the same `jti`.
  #
  # One ETS table per node: an assertion replayed to another node of a
  # cluster within its lifetime is not caught, which is why the
  # assertions Sake accepts are short-lived.
  use GenServer

  @table __MODULE__
  @sweep_every 60_000
  @leeway 30

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [nil]}}

  @doc """
  Records `jti` from `issuer`, valid until `exp`; `:ok` the first time,
  `{:error, :replayed}` after. Atomic: of two concurrent calls with the
  same key, exactly one gets `:ok`.
  """
  @spec once(String.t(), String.t(), number()) :: :ok | {:error, :replayed}
  def once(issuer, jti, exp) do
    if :ets.insert_new(@table, {{issuer, jti}, exp + @leeway}),
      do: :ok,
      else: {:error, :replayed}
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_every)
end
