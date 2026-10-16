defmodule Sake.Auth.Store.ETS do
  @moduledoc """
  An in-memory store for development and tests on one node. Everything is
  lost on restart.
  """
  @behaviour Sake.Auth.Store

  @tables %{
    clients: __MODULE__.Clients,
    codes: __MODULE__.Codes,
    tokens: __MODULE__.Tokens,
    consents: __MODULE__.Consents
  }

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [nil]}}

  # An `Agent`, not `use GenServer`: a GenServer's `init/1` callback would
  # collide with the `Sake.Auth.Store` behaviour's `init/1` below. It owns
  # the tables, and serializes the operations that must be atomic:
  # consuming a code or a refresh token, storing a code's tokens, and
  # revoking a family.
  def start_link(_) do
    Agent.start_link(
      fn ->
        for {_k, name} <- @tables,
            do: :ets.new(name, [:named_table, :public, :set, read_concurrency: true])

        nil
      end,
      name: __MODULE__
    )
  end

  @impl Sake.Auth.Store
  def init(_opts), do: nil

  @impl Sake.Auth.Store
  def put_client(_s, client), do: insert(:clients, client.id, client)
  @impl Sake.Auth.Store
  def get_client(_s, id), do: lookup(:clients, id)
  @impl Sake.Auth.Store
  def list_clients(_s), do: :ets.tab2list(@tables.clients) |> Enum.map(&elem(&1, 1))
  @impl Sake.Auth.Store
  def delete_client(_s, id) do
    :ets.delete(@tables.clients, id)
    :ok
  end

  # A code is kept with its state, `:unused`, `:used` or `:revoked`, until
  # it expires: a consumed code's row is the fence `put_code_tokens/3` and
  # `revoke_family/2` meet on, as in the Ecto store.
  @impl Sake.Auth.Store
  def put_code(_s, code) do
    :ets.insert(@tables.codes, {code.hash, code, :unused})
    :ok
  end

  @impl Sake.Auth.Store
  def consume_code(_s, hash) do
    atomically(fn ->
      case :ets.lookup(@tables.codes, hash) do
        [{^hash, code, :unused}] ->
          :ets.insert(@tables.codes, {hash, code, :used})
          {:ok, code}

        _ ->
          :error
      end
    end)
  end

  @impl Sake.Auth.Store
  def put_code_tokens(_s, code_hash, tokens) do
    atomically(fn ->
      case :ets.lookup(@tables.codes, code_hash) do
        [{^code_hash, _code, :used}] -> Enum.each(tokens, &insert(:tokens, &1.id, &1))
        _ -> :revoked
      end
    end)
  end

  @impl Sake.Auth.Store
  def put_token(_s, token), do: insert(:tokens, token.id, token)

  @impl Sake.Auth.Store
  def get_token(_s, kind, hash) do
    case :ets.match_object(@tables.tokens, {:_, %{kind: kind, hash: hash}}) do
      [{_, token}] -> {:ok, token}
      _ -> :error
    end
  end

  # Two concurrent callers can never both observe `used_at: nil` for the
  # same hash, so exactly one of them marks it used.
  @impl Sake.Auth.Store
  def consume_refresh(_s, hash) do
    atomically(fn ->
      case :ets.match_object(@tables.tokens, {:_, %{kind: :refresh, hash: hash}}) do
        [{id, %{used_at: nil} = record}] ->
          insert(:tokens, id, %{record | used_at: now()})
          {:ok, record}

        [{_id, record}] ->
          {:error, :used, record}

        [] ->
          :error
      end
    end)
  end

  @impl Sake.Auth.Store
  def revoke_token(_s, id), do: update(:tokens, id, &%{&1 | revoked_at: &1.revoked_at || now()})

  # A family born of a code also revokes the code's row, so that a pair
  # not stored yet never is (see `put_code_tokens/3`); then the family's
  # tokens are swept. Nothing is kept for a family that does not exist:
  # an unknown code costs nothing. A pair a refresh is about to store is
  # the token endpoint's to catch: it checks after storing it.
  @impl Sake.Auth.Store
  def revoke_family(_s, family_id) do
    atomically(fn ->
      case :ets.lookup(@tables.codes, family_id) do
        [{^family_id, code, _state}] -> :ets.insert(@tables.codes, {family_id, code, :revoked})
        [] -> :ok
      end

      ids = :ets.select(@tables.tokens, [{{:"$1", %{family_id: family_id}}, [], [:"$1"]}])
      Enum.each(ids, &update(:tokens, &1, fn t -> %{t | revoked_at: t.revoked_at || now()} end))
    end)
  end

  # Single-use JWTs are this node's to remember: `Sake.Auth.Replay` keeps
  # and sweeps the table.
  @impl Sake.Auth.Store
  def once(_s, key, expires_at), do: Sake.Auth.Replay.local_once(key, expires_at)

  @impl Sake.Auth.Store
  def prune_once(_s, _now), do: :ok

  @impl Sake.Auth.Store
  def tokens_for_subject(_s, subject_id),
    do: for({_, %{subject_id: ^subject_id} = t} <- :ets.tab2list(@tables.tokens), do: t)

  @impl Sake.Auth.Store
  def put_consent(_s, consent),
    do: insert(:consents, {consent.subject_id, consent.client_id, consent.resource}, consent)

  @impl Sake.Auth.Store
  def get_consent(_s, subject_id, client_id, resource),
    do: lookup(:consents, {subject_id, client_id, resource})

  @impl Sake.Auth.Store
  def delete_consent(_s, subject_id, client_id, :all) do
    :ets.match_delete(@tables.consents, {{subject_id, client_id, :_}, :_})
    :ok
  end

  def delete_consent(_s, subject_id, client_id, resource) do
    :ets.delete(@tables.consents, {subject_id, client_id, resource})
    :ok
  end

  @impl Sake.Auth.Store
  def prune(_s, now, consents_before) do
    prune_expired(now)
    tokens = :ets.tab2list(@tables.tokens)

    for {key, %{inserted_at: at} = consent} <- :ets.tab2list(@tables.consents),
        DateTime.compare(at, consents_before) == :lt,
        not Enum.any?(tokens, &live_refresh?(&1, consent, now)),
        do: :ets.delete(@tables.consents, key)

    :ok
  end

  defp live_refresh?({_, t}, consent, now) do
    t.kind == :refresh and t.subject_id == consent.subject_id and
      t.client_id == consent.client_id and t.resource == consent.resource and
      t.revoked_at == nil and DateTime.compare(t.expires_at, now) == :gt
  end

  defp prune_expired(now) do
    for {hash, %{expires_at: exp}, _state} <- :ets.tab2list(@tables.codes),
        DateTime.compare(exp, now) != :gt,
        do: :ets.delete(@tables.codes, hash)

    for {id, %{expires_at: exp}} <- :ets.tab2list(@tables.tokens),
        DateTime.compare(exp, now) != :gt,
        do: :ets.delete(@tables.tokens, id)

    :ok
  end

  # Runs `fun` in the Agent, serialized with every other call made through it.
  defp atomically(fun), do: Agent.get(__MODULE__, fn nil -> fun.() end)

  defp insert(table, key, value) do
    :ets.insert(@tables[table], {key, value})
    :ok
  end

  defp lookup(table, key) do
    case :ets.lookup(@tables[table], key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  defp update(table, key, fun) do
    case lookup(table, key) do
      {:ok, value} -> insert(table, key, fun.(value))
      :error -> :ok
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
