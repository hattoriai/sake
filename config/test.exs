import Config

config :sake, SakeTest.Repo,
  url: System.get_env("DATABASE_URL", "ecto://postgres@localhost/sake_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :sake, ecto_repos: [SakeTest.Repo]
config :logger, level: :warning
