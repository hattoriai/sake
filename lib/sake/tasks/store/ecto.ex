if Code.ensure_loaded?(Ecto.Query) do
  defmodule Sake.Tasks.Store.Ecto do
    @moduledoc """
    The task store for an endpoint on several nodes:
    `tasks: [store: {Sake.Tasks.Store.Ecto, repo: MyApp.Repo}]` with the
    table from `Sake.Tasks.Migration`. Every node reads and writes the same
    rows, so any node serves any task's `tasks/get`, `tasks/update` and
    `tasks/cancel`. Tested on Postgres.
    """
    @behaviour Sake.Tasks.Store
    import Ecto.Query

    alias Sake.Tasks.Record
    alias Sake.Tasks.Store.Ecto.Task, as: Row

    @impl true
    def init(opts), do: %{repo: Keyword.fetch!(opts, :repo), prefix: opts[:prefix]}

    # A transaction-scoped advisory lock on the owner serializes its
    # inserts, on every node: the count a new task is checked against
    # cannot change before the task is in.
    @impl true
    def insert(%{repo: repo} = s, %Record{} = r, max) do
      {:ok, result} =
        repo.transaction(fn ->
          <<key::signed-64, _::binary>> = :crypto.hash(:sha256, "sake_tasks:#{r.principal}")
          repo.query!("SELECT pg_advisory_xact_lock($1)", [key])

          if max == :infinity or live(s, r.principal, r.created_at) < max do
            {:ok, _} = repo.insert(struct!(Row, [id: r.id] ++ fields(r)), prefix: s.prefix)
            :ok
          else
            :full
          end
        end)

      result
    end

    defp live(%{repo: repo} = s, principal, now) do
      now = usec(now)

      query =
        from(t in Row,
          where:
            t.principal == ^principal and t.status in ["working", "input_required"] and
              t.expires_at > ^now,
          select: count()
        )

      repo.one(query, prefix: s.prefix)
    end

    @impl true
    def get(%{repo: repo} = s, id) do
      case repo.get(Row, id, prefix: s.prefix) do
        nil -> :error
        row -> {:ok, record(row)}
      end
    end

    # The row is locked for the length of the transaction, so concurrent
    # updates of one task (a worker asking for input while a `tasks/update`
    # answers, on two nodes) apply one after the other.
    @impl true
    def update(%{repo: repo} = s, id, fun) do
      result =
        repo.transaction(fn ->
          query = from(t in Row, where: t.id == ^id, lock: "FOR UPDATE")

          case repo.one(query, prefix: s.prefix) do
            nil ->
              repo.rollback(:not_found)

            row ->
              before = record(row)
              updated = fun.(before)

              repo.update_all(from(t in Row, where: t.id == ^id), [set: fields(updated)],
                prefix: s.prefix
              )

              {before, updated}
          end
        end)

      case result do
        {:ok, {before, updated}} -> {:ok, before, updated}
        {:error, :not_found} -> :error
      end
    end

    @impl true
    def prune(%{repo: repo} = s, now) do
      now = usec(now)
      repo.delete_all(from(t in Row, where: t.expires_at <= ^now), prefix: s.prefix)
      :ok
    end

    defp fields(%Record{} = r) do
      [
        principal: r.principal,
        tool: r.tool,
        scopes: r.scopes,
        status: Atom.to_string(r.status),
        status_message: r.status_message,
        input_requests: r.input_requests,
        answers: r.answers,
        result: r.result,
        error: r.error,
        ttl_ms: r.ttl_ms,
        poll_interval_ms: r.poll_interval_ms,
        created_at: usec(r.created_at),
        updated_at: usec(r.updated_at),
        expires_at: usec(r.expires_at)
      ]
    end

    defp record(row) do
      %Record{
        id: row.id,
        principal: row.principal,
        tool: row.tool,
        scopes: row.scopes || [],
        status: String.to_existing_atom(row.status),
        status_message: row.status_message,
        input_requests: row.input_requests || %{},
        answers: row.answers || %{},
        result: row.result,
        error: row.error,
        ttl_ms: row.ttl_ms,
        poll_interval_ms: row.poll_interval_ms,
        created_at: DateTime.truncate(row.created_at, :millisecond),
        updated_at: DateTime.truncate(row.updated_at, :millisecond),
        expires_at: DateTime.truncate(row.expires_at, :millisecond)
      }
    end

    # Sake keeps times to the millisecond; the column type wants them
    # written with microsecond precision.
    defp usec(%DateTime{microsecond: {us, _}} = at), do: %{at | microsecond: {us, 6}}
  end
end
