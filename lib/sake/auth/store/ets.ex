defmodule Sake.Auth.Store.ETS do
  @moduledoc """
  An in-memory store for development and tests on one node. Everything is
  lost on restart.
  """
  @behaviour Sake.Auth.Store

  @tables %{
    clients: __MODULE__.Clients,
    codes: __MODULE__.Codes,
    device_grants: __MODULE__.DeviceGrants,
    tokens: __MODULE__.Tokens,
    consents: __MODULE__.Consents
  }

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [nil]}}

  # An `Agent`, not `use GenServer`: a GenServer's `init/1` callback would
  # collide with the `Sake.Auth.Store` behaviour's `init/1` below. It owns
  # the tables, and serializes the operations that must be atomic:
  # consuming a code or a refresh token, deciding on or polling a device
  # grant, storing a code's or a device grant's tokens, and revoking a
  # family.
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

  # A device grant is kept with its fence, `:live` or `:revoked`, as a
  # code is with its state: `put_device_tokens/3` and `revoke_family/2`
  # meet on it.
  @impl Sake.Auth.Store
  def put_device_grant(_s, grant) do
    :ets.insert(@tables.device_grants, {grant.hash, grant, :live})
    :ok
  end

  @impl Sake.Auth.Store
  def get_device_grant_by_user_code(_s, user_code_hash) do
    case :ets.match_object(@tables.device_grants, {:_, %{user_code_hash: user_code_hash}, :_}) do
      [{_hash, grant, _fence}] -> {:ok, grant}
      _ -> :error
    end
  end

  @impl Sake.Auth.Store
  def decide_device_grant(_s, hash, decision) do
    atomically(fn ->
      case :ets.lookup(@tables.device_grants, hash) do
        [{^hash, %{status: :pending} = grant, fence}] ->
          :ets.insert(@tables.device_grants, {hash, decided(grant, decision), fence})
          :ok

        _ ->
          :error
      end
    end)
  end

  @impl Sake.Auth.Store
  def poll_device_grant(_s, hash, client_id, now) do
    atomically(fn ->
      case :ets.lookup(@tables.device_grants, hash) do
        [{^hash, grant, fence}] ->
          grant |> Sake.Auth.DeviceGrant.poll(client_id, now) |> polled(fence)

        [] ->
          :error
      end
    end)
  end

  @impl Sake.Auth.Store
  def put_device_tokens(_s, hash, tokens) do
    atomically(fn ->
      case :ets.lookup(@tables.device_grants, hash) do
        [{^hash, %{status: :issued}, :live}] -> Enum.each(tokens, &insert(:tokens, &1.id, &1))
        _ -> :revoked
      end
    end)
  end

  defp polled({answer, nil}, _fence), do: answer

  defp polled({answer, grant}, fence) do
    :ets.insert(@tables.device_grants, {grant.hash, grant, fence})
    answer
  end

  defp decided(grant, {:approved, subject_id, scopes}),
    do: %{grant | status: :approved, subject_id: subject_id, scopes: scopes}

  defp decided(grant, :denied), do: %{grant | status: :denied}

  # Serialized with `revoke_family/2` too: a revocation's sweep either
  # runs before the insert (and revokes the refresh token a rotation
  # consumed, which the token endpoint checks after storing the new pair)
  # or after it (and revokes the new pair).
  @impl Sake.Auth.Store
  def put_token(_s, token), do: atomically(fn -> insert(:tokens, token.id, token) end)

  @impl Sake.Auth.Store
  def put_rotated_tokens(_s, refresh_hash, tokens) do
    atomically(fn ->
      case :ets.match_object(@tables.tokens, {:_, %{kind: :refresh, hash: refresh_hash}}) do
        [{_id, %{revoked_at: nil}}] -> Enum.each(tokens, &insert(:tokens, &1.id, &1))
        _ -> :revoked
      end
    end)
  end

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

  # A family born of a code (or a device grant) also revokes the code's
  # row, so that a pair not stored yet never is (see `put_code_tokens/3`
  # and `put_device_tokens/3`); then the family's
  # tokens are swept. Nothing is kept for a family that does not exist:
  # an unknown code costs nothing. A pair a refresh is about to store is
  # the token endpoint's to catch: it checks after storing it (see
  # `put_token/2`).
  @impl Sake.Auth.Store
  def revoke_family(_s, family_id) do
    atomically(fn ->
      case :ets.lookup(@tables.codes, family_id) do
        [{^family_id, code, _state}] -> :ets.insert(@tables.codes, {family_id, code, :revoked})
        [] -> :ok
      end

      case :ets.lookup(@tables.device_grants, family_id) do
        [{^family_id, grant, _fence}] ->
          :ets.insert(@tables.device_grants, {family_id, grant, :revoked})

        [] ->
          :ok
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
  def prune(_s, now, before) do
    prune_expired(now)
    tokens = :ets.tab2list(@tables.tokens)

    for {key, %{inserted_at: at} = consent} <- :ets.tab2list(@tables.consents),
        DateTime.compare(at, before.consents) == :lt,
        not Enum.any?(tokens, &live_refresh?(&1, consent, now)),
        do: :ets.delete(@tables.consents, key)

    prune_unused_clients(now, before.unused_clients)
  end

  # What is left of the codes and device grants is unexpired: a client
  # with one of them, an unrevoked unexpired token or a consent is in use.
  defp prune_unused_clients(now, registered_before) do
    in_use =
      MapSet.new(
        Enum.concat([
          for({_, t} <- :ets.tab2list(@tables.tokens), live?(t, now), do: t.client_id),
          for({{_, client_id, _}, _} <- :ets.tab2list(@tables.consents), do: client_id),
          for({_, code, _} <- :ets.tab2list(@tables.codes), do: code.client_id),
          for({_, grant, _} <- :ets.tab2list(@tables.device_grants), do: grant.client_id)
        ])
      )

    for {id, %{kind: :dynamic, inserted_at: %DateTime{} = at}} <- :ets.tab2list(@tables.clients),
        DateTime.compare(at, registered_before) == :lt,
        not MapSet.member?(in_use, id),
        do: :ets.delete(@tables.clients, id)

    :ok
  end

  defp live?(t, now), do: t.revoked_at == nil and DateTime.compare(t.expires_at, now) == :gt

  defp live_refresh?({_, t}, consent, now) do
    t.kind == :refresh and t.subject_id == consent.subject_id and
      t.client_id == consent.client_id and t.resource == consent.resource and
      t.revoked_at == nil and DateTime.compare(t.expires_at, now) == :gt
  end

  defp prune_expired(now) do
    for {hash, %{expires_at: exp}, _state} <- :ets.tab2list(@tables.codes),
        DateTime.compare(exp, now) != :gt,
        do: :ets.delete(@tables.codes, hash)

    for {hash, %{expires_at: exp}, _fence} <- :ets.tab2list(@tables.device_grants),
        DateTime.compare(exp, now) != :gt,
        do: :ets.delete(@tables.device_grants, hash)

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
