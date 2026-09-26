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
  # collide with the `Sake.Auth.Store` behaviour's `init/1` below. Its state
  # is a map of `family_id => revoked_at`, so a family revocation is not
  # just a sweep of the rows that exist when it runs: a token inserted for
  # an already-revoked family (a race between rotating a refresh token and
  # a concurrent reuse of it) is still born revoked.
  def start_link(_) do
    Agent.start_link(
      fn ->
        for {_k, name} <- @tables,
            do: :ets.new(name, [:named_table, :public, :set, read_concurrency: true])

        %{}
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

  @impl Sake.Auth.Store
  def put_code(_s, code), do: insert(:codes, code.hash, code)

  @impl Sake.Auth.Store
  def consume_code(_s, hash) do
    case :ets.take(@tables.codes, hash) do
      [{^hash, code}] -> {:ok, code}
      [] -> :error
    end
  end

  # Goes through the Agent too, so it is serialized with `revoke_family/2`:
  # whichever of the two runs last still sees the other's effect, so a
  # token for an already-revoked family is inserted already revoked.
  @impl Sake.Auth.Store
  def put_token(_s, token) do
    Agent.get_and_update(__MODULE__, fn revoked ->
      insert(:tokens, token.id, born_revoked(token, revoked))
      {:ok, revoked}
    end)
  end

  defp born_revoked(token, revoked) do
    case Map.get(revoked, token.family_id) do
      nil -> token
      at -> %{token | revoked_at: token.revoked_at || at}
    end
  end

  @impl Sake.Auth.Store
  def get_token(_s, kind, hash) do
    case :ets.match_object(@tables.tokens, {:_, %{kind: kind, hash: hash}}) do
      [{_, token}] -> {:ok, token}
      _ -> :error
    end
  end

  # Runs inside the owner Agent process, which serializes every call made
  # through it: two concurrent callers can never both observe `used_at:
  # nil` for the same hash, so exactly one of them marks it used.
  @impl Sake.Auth.Store
  def consume_refresh(_s, hash) do
    Agent.get_and_update(__MODULE__, fn revoked ->
      result =
        case :ets.match_object(@tables.tokens, {:_, %{kind: :refresh, hash: hash}}) do
          [{id, %{used_at: nil} = record}] ->
            insert(:tokens, id, %{record | used_at: now()})
            {:ok, record}

          [{_id, record}] ->
            {:error, :used, record}

          [] ->
            :error
        end

      {result, revoked}
    end)
  end

  @impl Sake.Auth.Store
  def revoke_token(_s, id), do: update(:tokens, id, &%{&1 | revoked_at: &1.revoked_at || now()})

  # Also goes through the Agent: it records the family as revoked (so a
  # token inserted for it afterward is born revoked, see `put_token/2`)
  # and sweeps the rows that already exist, atomically in the same step.
  @impl Sake.Auth.Store
  def revoke_family(_s, family_id) do
    Agent.get_and_update(__MODULE__, fn revoked ->
      for {id, %{family_id: ^family_id}} <- :ets.tab2list(@tables.tokens),
          do: update(:tokens, id, &%{&1 | revoked_at: &1.revoked_at || now()})

      {:ok, Map.put_new(revoked, family_id, now())}
    end)
  end

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
    for {hash, %{expires_at: exp}} <- :ets.tab2list(@tables.codes),
        DateTime.compare(exp, now) != :gt,
        do: :ets.delete(@tables.codes, hash)

    for {id, %{expires_at: exp}} <- :ets.tab2list(@tables.tokens),
        DateTime.compare(exp, now) != :gt,
        do: :ets.delete(@tables.tokens, id)

    :ok
  end

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
