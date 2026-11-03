{:ok, _} =
  Supervisor.start_link([Sake.Plug.Streams.child_spec([]), {Sake.Tasks, poll_interval: 50}],
    strategy: :one_for_one,
    name: SakeTest.Supervisor
  )

_ = Ecto.Adapters.Postgres.storage_up(SakeTest.Repo.config())
{:ok, _} = SakeTest.Repo.start_link()

Ecto.Migrator.run(SakeTest.Repo, [{0, SakeTest.Migration}, {1, SakeTest.TasksMigration}], :up,
  all: true,
  log: false
)

Ecto.Adapters.SQL.Sandbox.mode(SakeTest.Repo, :manual)

# The same stores on SQLite, from a fresh file.
_ = Ecto.Adapters.SQLite3.storage_down(SakeTest.SQLiteRepo.config())
_ = Ecto.Adapters.SQLite3.storage_up(SakeTest.SQLiteRepo.config())
{:ok, _} = SakeTest.SQLiteRepo.start_link()

Ecto.Migrator.run(
  SakeTest.SQLiteRepo,
  [{0, SakeTest.Migration}, {1, SakeTest.TasksMigration}],
  :up,
  all: true,
  log: false
)

Ecto.Adapters.SQL.Sandbox.mode(SakeTest.SQLiteRepo, :manual)

ExUnit.start()
