defmodule Sake.Auth.StoreEctoTest do
  use SakeTest.AuthCase, async: false
  @moduletag store: :ecto
  use SakeTest.StoreCases

  test "the migration is reversible" do
    opts = [all: true, log: false, migration_lock: false]
    Ecto.Migrator.run(SakeTest.Repo, [{0, SakeTest.Migration}], :down, opts)
    Ecto.Migrator.run(SakeTest.Repo, [{0, SakeTest.Migration}], :up, opts)
  end
end
