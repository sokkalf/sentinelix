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

# ## Data retention
#
#   RETENTION_DAYS         days to keep raw check results (default 90)
#   ROLLUP_RETENTION_DAYS  days to keep the hourly rollups used for long-term
#                          uptime statistics (default 365)
#
# 0 keeps the data forever.
retention_env = fn name ->
  case System.get_env(name) do
    nil ->
      nil

    value ->
      case Integer.parse(String.trim(value)) do
        {days, ""} when days >= 0 -> days
        _ -> raise "#{name} must be a non-negative integer (days), got: #{inspect(value)}"
      end
  end
end

retention =
  Enum.reject(
    [
      retention_days: retention_env.("RETENTION_DAYS"),
      rollup_retention_days: retention_env.("ROLLUP_RETENTION_DAYS")
    ],
    fn {_key, days} -> is_nil(days) end
  )

if retention != [] do
  config :sentinelix, Sentinelix.Stats, retention
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

  # Bearer token for GET /metrics (Prometheus). Unset: /metrics is disabled
  # (404).
  if metrics_token = env.("METRICS_TOKEN") do
    config :sentinelix, :metrics_token, metrics_token
  end

  config :sentinelix,
         :bootstrap_admin,
         reject_nil.(email: env.("ADMIN_EMAIL"), password: System.get_env("ADMIN_PASSWORD"))

  # ## Notifications
  #
  #   NOTIFICATIONS_EMAIL_FROM  sender of notification emails, e.g.
  #                             "Sentinelix <alerts@example.com>" or a bare
  #                             address (default sentinelix@localhost)
  #
  # Channel configs (tokens, webhook URLs) are encrypted in the database with
  # a key derived from SECRET_KEY_BASE: changing it makes them unreadable.
  if from = env.("NOTIFICATIONS_EMAIL_FROM") do
    email_from =
      case Regex.run(~r/^\s*(.*?)\s*<([^>]+)>\s*$/, from) do
        [_, "", address] -> address
        [_, name, address] -> {name, address}
        nil -> from
      end

    config :sentinelix, Sentinelix.Notifications, email_from: email_from
  end

  # ## Rate limiting and reverse proxies
  #
  #   LOGIN_RATE_LIMIT   password login attempts per minute and client IP
  #                      (default 10, 0 disables)
  #   PUSH_RATE_LIMIT    push endpoint requests per minute and client IP
  #                      (default 300, 0 disables)
  #   EVENTS_RATE_LIMIT  monitor events posted per minute and client IP
  #                      (default 120, 0 disables)
  #   WALL_RATE_LIMIT    wall display page loads and (re)connects per
  #                      minute and client IP (default 60, 0 disables)
  #   TRUSTED_PROXIES    comma separated IPs/CIDR ranges of reverse proxies
  #                      whose X-Forwarded-For header is trusted, e.g.
  #                      "127.0.0.1,::1,172.16.0.0/12". Unset: the header is
  #                      ignored and the peer address is the client.
  rate_limit = fn name ->
    if value = env.(name) do
      case Integer.parse(value) do
        {limit, ""} when limit >= 0 -> {limit, 60_000}
        _ -> raise "#{name} must be a non-negative integer (per minute), got: #{inspect(value)}"
      end
    end
  end

  config :sentinelix,
         Sentinelix.RateLimit,
         reject_nil.(
           login: rate_limit.("LOGIN_RATE_LIMIT"),
           push: rate_limit.("PUSH_RATE_LIMIT"),
           events: rate_limit.("EVENTS_RATE_LIMIT"),
           wall: rate_limit.("WALL_RATE_LIMIT")
         )

  if trusted_proxies = env_list.("TRUSTED_PROXIES", [",", " "]) do
    config :sentinelix, :trusted_proxies, trusted_proxies
  end

  # Time zone new maintenance windows start out in (IANA name, default
  # Etc/UTC). The UI shows timestamps in the browser's time zone.
  if default_timezone = env.("DEFAULT_TIMEZONE") do
    config :sentinelix, :default_timezone, default_timezone
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # ECTO_SSL: "true" connects over TLS and verifies the server certificate
  # against the system CA store; "noverify" uses TLS without verification
  # (self-signed certificates). Unset or "false": no TLS.
  ecto_ssl =
    case System.get_env("ECTO_SSL", "false") |> String.trim() |> String.downcase() do
      value when value in ["", "false", "0", "no", "off"] -> false
      value when value in ["true", "1", "yes", "on"] -> true
      "noverify" -> [verify: :verify_none]
      other -> raise "ECTO_SSL must be true, false or noverify, got: #{inspect(other)}"
    end

  config :sentinelix, Sentinelix.Repo,
    ssl: ecto_ssl,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
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

  # The public URL (used for OIDC redirect URIs and links in notifications)
  # and the host browsers connect to (LiveView websockets only accept this
  # origin host). PHX_SCHEME/PHX_URL_PORT default to https on 443; set
  # PHX_SCHEME=http (port 80) or PHX_URL_PORT=4000 when not behind a TLS
  # terminating proxy.
  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the host name Sentinelix is reached at, e.g. uptime.example.com
      """

  scheme = System.get_env("PHX_SCHEME", "https")

  unless scheme in ["http", "https"] do
    raise "PHX_SCHEME must be http or https, got: #{inspect(scheme)}"
  end

  url_port =
    String.to_integer(
      System.get_env("PHX_URL_PORT", if(scheme == "https", do: "443", else: "80"))
    )

  config :sentinelix, SentinelixWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT", "4000"))
    ],
    secret_key_base: secret_key_base

  # ## Email (SMTP)
  #
  #   SMTP_HOST      mail server; unset: no mail adapter, email
  #                  notifications fail and a warning is logged on boot
  #   SMTP_PORT      default 587 (465 with SMTP_TLS=ssl)
  #   SMTP_USERNAME  / SMTP_PASSWORD  credentials (no auth when unset)
  #   SMTP_TLS       starttls (default, required), if_available (STARTTLS
  #                  when offered), ssl (implicit TLS) or none
  #
  # Certificates are verified against the system CA store.
  smtp_env = fn name ->
    case System.get_env(name) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  if smtp_host = smtp_env.("SMTP_HOST") do
    tls_mode = String.downcase(smtp_env.("SMTP_TLS") || "starttls")

    unless tls_mode in ["starttls", "if_available", "ssl", "none"] do
      raise "SMTP_TLS must be starttls, if_available, ssl or none, got: #{inspect(tls_mode)}"
    end

    verify_options = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(smtp_host),
      depth: 99,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    username = smtp_env.("SMTP_USERNAME")
    implicit_tls = tls_mode == "ssl"

    starttls =
      case tls_mode do
        "starttls" -> :always
        "if_available" -> :if_available
        _ -> :never
      end

    config :sentinelix, Sentinelix.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_host,
      port: String.to_integer(smtp_env.("SMTP_PORT") || if(implicit_tls, do: "465", else: "587")),
      username: username,
      password: System.get_env("SMTP_PASSWORD"),
      auth: if(username, do: :always, else: :never),
      ssl: implicit_tls,
      sockopts: if(implicit_tls, do: verify_options, else: []),
      tls: starttls,
      tls_options: verify_options,
      no_mx_lookups: true,
      retries: 1
  else
    config :sentinelix, Sentinelix.Mailer, adapter: nil
  end
end
