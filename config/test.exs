import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :sentinelix, SentinelixWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Rq+YAxwUgugR1Viynb+JtCEPL49hGRPNa+Z2k67xajr/EjbOWNQYKhxqIr0Z/Bu1",
  server: false

# In test we don't send emails.
config :sentinelix, Sentinelix.Mailer,
  adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
