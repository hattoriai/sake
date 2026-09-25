import Config

config :sake, SakeTest.Repo,
  database: "sake_test",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :sake, ecto_repos: [SakeTest.Repo]
config :logger, level: :warning
