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
  # collide with the `Sake.Auth.Store` behaviour's `init/1` below.
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

  @impl Sake.Auth.Store
  def put_code(_s, code), do: insert(:codes, code.hash, code)

  @impl Sake.Auth.Store
  def consume_code(_s, hash) do
    case :ets.take(@tables.codes, hash) do
      [{^hash, code}] -> {:ok, code}
      [] -> :error
    end
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

  @impl Sake.Auth.Store
  def mark_used(_s, id), do: update(:tokens, id, &%{&1 | used_at: now()})
  @impl Sake.Auth.Store
  def revoke_token(_s, id), do: update(:tokens, id, &%{&1 | revoked_at: &1.revoked_at || now()})

  @impl Sake.Auth.Store
  def revoke_family(_s, family_id) do
    for {id, %{family_id: ^family_id}} <- :ets.tab2list(@tables.tokens),
        do: update(:tokens, id, &%{&1 | revoked_at: &1.revoked_at || now()})

    :ok
  end

  @impl Sake.Auth.Store
  def tokens_for_subject(_s, subject_id),
    do: for({_, %{subject_id: ^subject_id} = t} <- :ets.tab2list(@tables.tokens), do: t)

  @impl Sake.Auth.Store
  def put_consent(_s, consent),
    do: insert(:consents, {consent.subject_id, consent.client_id}, consent)

  @impl Sake.Auth.Store
  def get_consent(_s, subject_id, client_id), do: lookup(:consents, {subject_id, client_id})
  @impl Sake.Auth.Store
  def delete_consent(_s, subject_id, client_id) do
    :ets.delete(@tables.consents, {subject_id, client_id})
    :ok
  end

  @impl Sake.Auth.Store
  def prune(_s, now) do
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
