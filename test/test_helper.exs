{:ok, _} =
  Supervisor.start_link([Sake.Plug.Streams.child_spec([])],
    strategy: :one_for_one,
    name: SakeTest.Supervisor
  )

_ = Ecto.Adapters.Postgres.storage_up(SakeTest.Repo.config())
{:ok, _} = SakeTest.Repo.start_link()
Ecto.Migrator.run(SakeTest.Repo, [{0, SakeTest.Migration}], :up, all: true, log: false)
Ecto.Adapters.SQL.Sandbox.mode(SakeTest.Repo, :manual)

ExUnit.start()
