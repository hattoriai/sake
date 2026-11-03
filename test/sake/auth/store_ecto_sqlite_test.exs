defmodule Sake.Auth.StoreEctoSQLiteTest do
  # The Ecto store on SQLite, which has no row locks: the transactions that
  # lock a row on Postgres are IMMEDIATE there (Sake.Auth.Store.Lock).
  use SakeTest.AuthCase, async: false
  @moduletag store: :sqlite
  use SakeTest.StoreCases
end
