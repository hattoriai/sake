import Config

config :sake, SakeTest.Repo,
  url: System.get_env("DATABASE_URL", "ecto://postgres@localhost/sake_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :sake, ecto_repos: [SakeTest.Repo]
config :logger, level: :warning

config :sake, SakeTest.PhoenixEndpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 0],
  server: true,
  render_errors: [formats: [json: SakeTest.ErrorJSON], layout: false],
  secret_key_base: String.duplicate("e", 64)

config :phoenix, :json_library, JSON
