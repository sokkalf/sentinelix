import Config

# Configure your database
#
# Connection settings are read from the PGHOST, PGPORT, PGUSER and
# PGPASSWORD environment variables (defaulting to a local Postgres with
# postgres/postgres). Alternatively, TEST_DATABASE_URL can be set to a
# full ecto://USER:PASS@HOST/DATABASE URL.
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :sentinelix, Sentinelix.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

if url = System.get_env("TEST_DATABASE_URL") do
  config :sentinelix, Sentinelix.Repo, url: url <> System.get_env("MIX_TEST_PARTITION", "")
else
  config :sentinelix, Sentinelix.Repo,
    username: System.get_env("PGUSER", "postgres"),
    password: System.get_env("PGPASSWORD", "postgres"),
    hostname: System.get_env("PGHOST", "localhost"),
    port: String.to_integer(System.get_env("PGPORT", "5432")),
    database: "sentinelix_test#{System.get_env("MIX_TEST_PARTITION")}"
end

# Only in tests are we speeding up hashing
config :bcrypt_elixir, :log_rounds, 1

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :sentinelix, SentinelixWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "tFOtr5dYg62R2g0ET2znAliGrUQ+o1VTt0T49BxOijQjzlCELLsMaCJEnF77gI4y",
  server: false

# In test we don't send emails
config :sentinelix, Sentinelix.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Developer-specific overrides go in config/test.local.exs, which is
# gitignored. Useful e.g. when your Postgres only lets you connect to
# specific databases:
#
#     import Config
#
#     config :sentinelix, Sentinelix.Repo,
#       database: "my_test_db",
#       maintenance_database: "my_test_db"
if File.exists?(Path.expand("test.local.exs", __DIR__)) do
  import_config "test.local.exs"
end
