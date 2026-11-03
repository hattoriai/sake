if Code.ensure_loaded?(Ecto.Query) do
  defmodule Sake.Auth.Store.Lock do
    @moduledoc false
    # A row lock for the Ecto stores (the auth store's, and the tasks'), on
    # every database Ecto speaks.
    #
    # Postgres and MySQL lock the row: `SELECT ... FOR UPDATE` inside the
    # transaction. SQLite has no row locks (ecto_sqlite3 refuses a query
    # with `lock:`), but one writer at a time for the whole database: the
    # transaction is `IMMEDIATE` instead, so it holds the write lock from
    # its first statement, and a concurrent writer waits for it, as it
    # waits for the row lock elsewhere.

    import Ecto.Query

    @doc "Runs `fun` in a transaction in which `locked/2` queries hold their rows."
    def transaction(repo, fun) do
      if sqlite?(repo),
        do: repo.transaction(fun, mode: :immediate),
        else: repo.transaction(fun)
    end

    @doc "The query, locking its rows `FOR UPDATE` where the database has row locks."
    def locked(query, repo) do
      if sqlite?(repo), do: query, else: lock(query, "FOR UPDATE")
    end

    @doc """
    Serializes the transactions that take the lock of `name` (a string),
    until they end: a transaction-scoped advisory lock on Postgres. On
    SQLite, `transaction/2` already holds the database's write lock.
    """
    def advisory(repo, name) do
      unless sqlite?(repo) do
        <<key::signed-64, _::binary>> = :crypto.hash(:sha256, name)
        repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
      end

      :ok
    end

    defp sqlite?(repo), do: repo.__adapter__() == Ecto.Adapters.SQLite3
  end
end
