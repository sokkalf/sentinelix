import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/sentinelix start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :sentinelix, SentinelixWeb.Endpoint, server: true
end

# The HTTP port defaults to 4000 in prod (and whatever config/dev.exs or
# config/dev.local.exs set in dev). Setting PORT overrides it in any env.
if port = System.get_env("PORT") do
  config :sentinelix, SentinelixWeb.Endpoint, http: [port: String.to_integer(port)]
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :sentinelix, SentinelixWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/sentinelix_web/router\.ex$"E,
        ~r"lib/sentinelix_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# ## Authentication
#
# OpenID Connect is the primary login (any compliant IdP). It is enabled when
# OIDC_ISSUER and OIDC_CLIENT_ID are set:
#
#   OIDC_ISSUER            issuer URL; discovery is read from
#                          <issuer>/.well-known/openid-configuration
#   OIDC_CLIENT_ID         client id (confidential client)
#   OIDC_CLIENT_SECRET     client secret (omit for a public client using PKCE)
#   OIDC_SCOPES            default "openid profile email"
#   OIDC_PROVIDER_NAME     button label, "Sign in with <name>" (default "SSO")
#   OIDC_GROUPS_CLAIM      claim holding the user's groups (default "groups")
#   OIDC_ALLOWED_GROUPS    comma separated; optional allow-lists - if none is
#   OIDC_ALLOWED_EMAILS    set, every user the IdP authenticates may log in,
#   OIDC_ALLOWED_DOMAINS   otherwise a user matching any of them may log in
#   OIDC_ALLOW_INSECURE_HTTP  "true" to allow a plain http:// IdP (dev only)
#
# The redirect URI to register at the IdP is <endpoint url>/auth/oidc/callback,
# and <endpoint url>/login as post-logout redirect URI.
#
# Local password login is a break-glass fallback:
#
#   LOCAL_AUTH_ENABLED     default: true when OIDC is not configured, else false
#   ADMIN_EMAIL / ADMIN_PASSWORD  create this local admin on boot if it does
#                          not exist (or use `mix sentinelix.create_admin`)
#
# Variables that are not set leave the configuration untouched, so the same
# settings can also be put in config/dev.local.exs. Tests configure auth
# explicitly and ignore these variables.
if config_env() != :test do
  env = fn name ->
    case System.get_env(name) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  env_list = fn name, separators ->
    if value = env.(name),
      do: String.split(value, separators, trim: true) |> Enum.map(&String.trim/1)
  end

  env_bool = fn name ->
    if value = env.(name), do: String.downcase(value) in ~w(1 true yes on)
  end

  reject_nil = fn opts -> Enum.reject(opts, fn {_key, value} -> is_nil(value) end) end

  config :sentinelix,
         :oidc,
         reject_nil.(
           issuer: env.("OIDC_ISSUER"),
           client_id: env.("OIDC_CLIENT_ID"),
           client_secret: env.("OIDC_CLIENT_SECRET"),
           scopes: env_list.("OIDC_SCOPES", [",", " "]),
           provider_name: env.("OIDC_PROVIDER_NAME"),
           groups_claim: env.("OIDC_GROUPS_CLAIM"),
           allowed_groups: env_list.("OIDC_ALLOWED_GROUPS", [","]),
           allowed_emails: env_list.("OIDC_ALLOWED_EMAILS", [",", " "]),
           allowed_domains: env_list.("OIDC_ALLOWED_DOMAINS", [",", " "]),
           allow_insecure_http: env_bool.("OIDC_ALLOW_INSECURE_HTTP")
         )

  if (local_auth_enabled = env_bool.("LOCAL_AUTH_ENABLED")) != nil do
    config :sentinelix, :local_auth_enabled, local_auth_enabled
  end

  config :sentinelix,
         :bootstrap_admin,
         reject_nil.(email: env.("ADMIN_EMAIL"), password: System.get_env("ADMIN_PASSWORD"))
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :sentinelix, Sentinelix.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :sentinelix, SentinelixWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT", "4000"))
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :sentinelix, SentinelixWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :sentinelix, SentinelixWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :sentinelix, Sentinelix.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Finch
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
