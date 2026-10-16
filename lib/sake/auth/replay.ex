defmodule Sake.Auth.Replay do
  @moduledoc false
  # The JWT IDs already seen, so a client assertion, a JWT grant (RFC 7523
  # §3, and the ID-JAG's `jti`) or a DPoP proof is accepted once. Each is
  # kept until its JWT can no longer be accepted (plus the clock leeway),
  # keyed by a digest of its issuer and `jti`: two issuers may well pick
  # the same `jti`, and a `jti` of any length costs the same.
  #
  # They are recorded in the replay store `Sake` was started with (its
  # `replay:` option, by default the `Sake.Auth` store), so with
  # `Sake.Auth.Store.Ecto` a JWT used on one node of a cluster is refused
  # on every other. Without a store (only external authorization servers,
  # no `replay:`), in an ETS table on each node. This process sweeps what
  # expired from both, every minute.
  use GenServer

  @table __MODULE__
  @sweep_every 60_000
  @leeway 30

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [nil]}}

  @doc "Sets the replay store: `{module, state}` of a `Sake.Auth.Store`, or nil for this node's table."
  @spec configure({module(), term()} | nil) :: :ok
  def configure(store), do: :persistent_term.put({__MODULE__, :store}, store)

  @doc """
  Records `jti` from `issuer`, valid until `exp`; `:ok` the first time,
  `{:error, :replayed}` after. Atomic: of two concurrent calls with the
  same key, on any node sharing the store, exactly one gets `:ok`.
  """
  @spec once(String.t(), String.t(), number()) :: :ok | {:error, :replayed}
  def once(issuer, jti, exp) do
    key = :sha256 |> :crypto.hash([issuer, 0, jti]) |> Base.url_encode64(padding: false)
    expires_at = trunc(exp) + @leeway

    result =
      case store() do
        nil -> local_once(key, expires_at)
        {module, state} -> module.once(state, key, expires_at)
      end

    if result == :ok, do: :ok, else: {:error, :replayed}
  end

  @doc "Records `key` in this node's table until `expires_at` (Unix seconds); `:ok` the first time, `:replayed` after."
  @spec local_once(String.t(), integer()) :: :ok | :replayed
  def local_once(key, expires_at) do
    if :ets.insert_new(@table, {key, expires_at}), do: :ok, else: :replayed
  end

  defp store, do: :persistent_term.get({__MODULE__, :store}, nil)

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

    with {module, store_state} <- store(),
         do: module.prune_once(store_state, now)

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_every)
end
