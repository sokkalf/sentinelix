# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :sentinelix,
  ecto_repos: [Sentinelix.Repo],
  generators: [timestamp_type: :utc_datetime]

# Authentication defaults; see config/runtime.exs for the environment
# variables (OIDC_*, LOCAL_AUTH_ENABLED, ADMIN_*) and Sentinelix.Auth.
config :sentinelix, :oidc, []
# nil = enabled only when OIDC is not configured
config :sentinelix, :local_auth_enabled, nil
config :sentinelix, :bootstrap_admin, []

# Data retention (days; nil or 0 keeps data forever). Raw check results are
# rolled up hourly; see Sentinelix.Stats.Rollup and config/runtime.exs
# (RETENTION_DAYS, ROLLUP_RETENTION_DAYS).
config :sentinelix, Sentinelix.Stats,
  retention_days: 90,
  rollup_retention_days: 365

# Configure the endpoint
config :sentinelix, SentinelixWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SentinelixWeb.ErrorHTML, json: SentinelixWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Sentinelix.PubSub,
  live_view: [signing_salt: "sdX5KMtR"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :sentinelix, Sentinelix.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  sentinelix: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  sentinelix: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :monitor_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
