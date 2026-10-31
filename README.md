# Sentinelix

A self-hosted uptime monitor built with Elixir and Phoenix, an alternative to
Uptime Kuma or Pingdom. It checks your websites, services and hosts, records
uptime and response times, alerts you when something goes down and shows
public status pages.

<!-- Screenshot: docs/screenshot.png (dashboard) -->

## Features

* **Check types:** HTTP(S) (status codes, redirects, TLS verification),
  keyword / JSON (body contains a keyword or a JSON path matches), TCP port,
  ping (ICMP), DNS records (A, AAAA, CNAME, MX, TXT, NS), TLS certificate
  expiry, PostgreSQL (login, query with expected result, replication status
  and lag) and push (heartbeat) monitors for cron jobs and backups.
* **Live dashboard** with per-monitor status, heartbeat bars, response time
  charts, uptime over 24 hours / 7 / 30 / 90 days and incident history
  (LiveView, updates without reloading).
* **Labels:** key/value labels on monitors (`env=prod`, `site=oslo`) to
  group, filter and search them.
* **Cloning:** "same checks as db1, but for db2" – copy a monitor's
  settings, labels and notification channels into a new one.
* **Notifications** by email, generic webhook, Slack, Discord, Telegram,
  ntfy and Gotify, on down, recovery and certificate warnings.
* **Maintenance windows** (one-off or recurring, time zone aware) that
  suppress alerts.
* **Public status pages** at `/status/<slug>`.
* **Login** through any OpenID Connect provider, with a local password
  login as break-glass fallback.
* **Operations:** `/healthz` health check, Prometheus `/metrics`, hourly
  rollups with configurable data retention, rate limiting of the public
  endpoints, a Docker image and a compose file.

## Quick start (Docker Compose)

```sh
git clone <this repository> sentinelix && cd sentinelix
cp .env.example .env
# Edit .env: set SECRET_KEY_BASE (openssl rand -base64 48), POSTGRES_PASSWORD
# and ADMIN_PASSWORD (12+ characters)
docker compose up -d
```

Open <http://localhost:4000> and sign in with `ADMIN_EMAIL` /
`ADMIN_PASSWORD`. [`docker-compose.yml`](docker-compose.yml) runs the app and
PostgreSQL 17 (data in the `db-data` volume); the app container runs pending
database migrations on every start and reports its health from `/healthz`.

For production, put Sentinelix behind a TLS terminating reverse proxy, set
`PHX_HOST` to its public host name, remove `PHX_SCHEME`/`PHX_URL_PORT` from
`.env` (defaults: `https`, 443) and set `TRUSTED_PROXIES` (see
[Reverse proxy](#reverse-proxy)).

## Configuration

All production settings are environment variables, read on boot by
[`config/runtime.exs`](config/runtime.exs). Required variables that are
missing, and invalid values, stop the boot with an error saying what is
wrong.

### General

| Variable | Description |
| --- | --- |
| `DATABASE_URL` | **Required.** `ecto://USER:PASS@HOST/DATABASE` |
| `SECRET_KEY_BASE` | **Required.** At least 64 random bytes, e.g. `openssl rand -base64 48`. Signs sessions and encrypts notification channel secrets – see the note below |
| `PHX_HOST` | **Required.** Public host name, e.g. `uptime.example.com`. Used in generated URLs (OIDC redirect URI, links in notifications); LiveView only accepts websocket connections from pages on this host |
| `PHX_SCHEME` | Scheme of the public URL, `https` (default) or `http` |
| `PHX_URL_PORT` | Port of the public URL (default 443 for https, 80 for http) |
| `PORT` | HTTP port the server listens on (default 4000) |
| `POOL_SIZE` | Database connections (default 10) |
| `ECTO_SSL` | `true`: connect to Postgres over TLS and verify its certificate against the system CA store; `noverify`: TLS without verification; default `false` |
| `ECTO_IPV6` | `true` to connect to the database over IPv6 |
| `DEFAULT_TIMEZONE` | IANA time zone new maintenance windows start out in (default `Etc/UTC`; the UI shows timestamps in the browser's time zone) |
| `RETENTION_DAYS` | Days to keep raw check results (default 90, 0 = forever) |
| `ROLLUP_RETENTION_DAYS` | Days to keep hourly rollups for long-term uptime statistics (default 365, 0 = forever) |
| `METRICS_TOKEN` | Bearer token for `/metrics`; unset: `/metrics` is disabled (404) |
| `SKIP_MIGRATIONS` | `true` to not run migrations when the container starts |

> **`SECRET_KEY_BASE` must stay the same.** Notification channel configs
> (tokens, webhook URLs, ...) are encrypted in the database with a key
> derived from it. Changing it logs everybody out and makes the stored
> channel configs unreadable: the channels then have to be set up again.

### Authentication

| Variable | Description |
| --- | --- |
| `OIDC_ISSUER` | Issuer URL of the OpenID Connect provider; OIDC is enabled when this and `OIDC_CLIENT_ID` are set |
| `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` | Client credentials (omit the secret for a public client with PKCE) |
| `OIDC_SCOPES` | Default `openid profile email` |
| `OIDC_PROVIDER_NAME` | Button label: "Sign in with ..." (default `SSO`) |
| `OIDC_GROUPS_CLAIM` | Claim with the user's groups (default `groups`; dotted paths such as `realm_access.roles` work) |
| `OIDC_ALLOWED_GROUPS` / `OIDC_ALLOWED_EMAILS` / `OIDC_ALLOWED_DOMAINS` | Comma separated allow-lists, see [OpenID Connect](#openid-connect) |
| `OIDC_ALLOW_INSECURE_HTTP` | `true` to allow a plain `http://` issuer (development only) |
| `LOCAL_AUTH_ENABLED` | Local password login; default `true` when OIDC is not configured, `false` when it is |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` | Create this local admin on boot unless it exists (password: 12-72 characters) |
| `LOGIN_RATE_LIMIT` | Password login attempts per minute and client IP (default 10, 0 disables) |

### Email

| Variable | Description |
| --- | --- |
| `SMTP_HOST` | SMTP server. Without it no mail adapter is configured: email notifications fail with an error and a warning is logged on boot |
| `SMTP_PORT` | Default 587 (465 with `SMTP_TLS=ssl`) |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | Credentials; no authentication when unset |
| `SMTP_TLS` | `starttls` (default; STARTTLS is required), `if_available`, `ssl` (implicit TLS, port 465) or `none`. Certificates are verified against the system CA store |
| `NOTIFICATIONS_EMAIL_FROM` | Sender, e.g. `Sentinelix <alerts@example.com>` (default `sentinelix@localhost`) |

### Reverse proxy and push endpoint

| Variable | Description |
| --- | --- |
| `TRUSTED_PROXIES` | Comma separated IP addresses / CIDR ranges of reverse proxies whose `X-Forwarded-For` header is trusted, e.g. `127.0.0.1,::1,172.16.0.0/12` |
| `PUSH_RATE_LIMIT` | Push endpoint requests per minute and client IP (default 300, 0 disables) |

## Deployment

### Docker image

```sh
docker build -t sentinelix .
docker run -d -p 4000:4000 --env-file .env \
  -e DATABASE_URL=ecto://sentinelix:secret@db.example.internal/sentinelix \
  sentinelix
```

The [`Dockerfile`](Dockerfile) builds a release on
`hexpm/elixir:1.19.4-erlang-28.3-debian-trixie` and copies it into a slim
Debian image that runs as `nobody` under `tini`. Its entrypoint
(`bin/start`) runs pending migrations, then starts the server; it has a
`HEALTHCHECK` on `/healthz`.

**Ping monitors** run the system `ping` (iputils), which is installed with
`CAP_NET_RAW` as a permitted file capability. It works with Docker's default
capabilities (which include `NET_RAW`; the compose file adds it explicitly
in case you drop all capabilities). Without `NET_RAW` ping falls back to
unprivileged ICMP sockets, which need the group of the process (`nobody` is
65534) in `net.ipv4.ping_group_range` – Docker sets
`0 2147483647` by default, on Kubernetes set the sysctl in the pod's
`securityContext` or keep `NET_RAW`.

### Prebuilt images

Pushing a `v*` tag makes CI ([`.forgejo/workflows/docker.yml`](.forgejo/workflows/docker.yml))
build the image with Buildah and push it to the Forgejo container registry as
the tag and as `latest`:

```sh
git tag v0.2.0 && git push origin v0.2.0
docker pull git.helsinki.internal.tynn.is/sokkalf/sentinelix:latest
```

To run it with the compose file, set
`SENTINELIX_IMAGE=git.helsinki.internal.tynn.is/sokkalf/sentinelix:latest` in
`.env` and run `docker compose pull && docker compose up -d --no-build`.
Pushing needs a `PUSH_TOKEN` repository secret (an access token with
`write:package` scope). Pull requests and pushes to master that touch the
Dockerfile, `mix.exs`/`mix.lock`, `config/` or `rel/` only build the image, to
check that it still builds.

### Release without Docker

```sh
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release

_build/prod/rel/sentinelix/bin/migrate   # run migrations
_build/prod/rel/sentinelix/bin/server    # start (PHX_SERVER=true is set)
_build/prod/rel/sentinelix/bin/start     # both of the above
```

The release needs the same environment variables at runtime (not at build
time) and the `ping` binary for ping monitors.

Mix tasks are not available in a release. Create a local admin or reset its
password with

```sh
ADMIN_EMAIL=admin@example.com ADMIN_PASSWORD='new password' bin/create_admin
# Docker Compose:
docker compose exec -e ADMIN_PASSWORD='new password' app bin/create_admin
```

(`Sentinelix.Release.create_admin/1`; resetting a password revokes the
user's sessions). A migration can be rolled back with
`bin/sentinelix eval 'Sentinelix.Release.rollback(Sentinelix.Repo, VERSION)'`.

### Reverse proxy

Run Sentinelix behind a reverse proxy that terminates TLS (Caddy, nginx,
Traefik, ...) and forward websockets (`/live`). Set `PHX_HOST` to the public
host name.

Set `TRUSTED_PROXIES` to the address(es) of the proxy. Sentinelix then takes
the client address from `X-Forwarded-For` (the rightmost address that isn't a
trusted proxy), which is used for rate limiting and in the logs. The header
is ignored for requests that don't come from a trusted proxy, so clients
can't spoof their address. Without `TRUSTED_PROXIES` behind a proxy, all
clients share the proxy's address and therefore a single rate limit bucket.

Pages reachable without logging in, if you want to restrict access at the
proxy:

* `/status/<slug>` – published status pages (and the `/live` websocket and
  `/assets` they use)
* `/api/push/<token>` – push monitors (must be reachable by whatever pushes)
* `/healthz` – health check, `/metrics` – Prometheus (bearer token)
* `/login`, `/auth/oidc`, `/auth/oidc/callback` – sign-in

Everything else requires a session.

### Rate limiting

Password logins (`POST /login`) and the push endpoint (`/api/push/<token>`)
are rate limited per client IP in fixed one-minute windows
(`LOGIN_RATE_LIMIT`, default 10; `PUSH_RATE_LIMIT`, default 300). Requests
over the limit get `429 Too Many Requests` with a `Retry-After` header. The
counters live in memory (ETS) and are per node.

## Authentication

All app pages require a login. Sign-in primarily goes through an external
**OpenID Connect** provider (Authentik, Keycloak, Authelia, Zitadel, Pocket ID,
...), with a local password login as break-glass fallback.

### OpenID Connect

Create a confidential client ("web application", authorization code flow) at
your IdP with:

  * **Redirect URI:** `https://<your host>/auth/oidc/callback`
  * **Post-logout redirect URI:** `https://<your host>/login` (used for
    RP-initiated logout when the IdP advertises an `end_session_endpoint`)
  * **Scopes:** `openid profile email` (plus whatever scope makes your IdP
    include the groups claim, e.g. `groups`, if you use `OIDC_ALLOWED_GROUPS`)

The host is `PHX_HOST` (with `PHX_SCHEME`/`PHX_URL_PORT`). PKCE (S256) is
used automatically when the IdP supports it. Then set `OIDC_ISSUER`,
`OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET` (see
[Authentication settings](#authentication)).

Without any `OIDC_ALLOWED_*` setting every user the IdP authenticates may log
in; otherwise a user matching any of the lists may. Groups are read from
`OIDC_GROUPS_CLAIM` (dotted paths such as `realm_access.roles` for Keycloak
realm roles work). Claims from the userinfo endpoint are merged into the ID
token claims, so a groups claim that only the userinfo endpoint returns works
too. Users are created on their first login and identified by issuer +
subject, not by email.

### Local break-glass login

`LOCAL_AUTH_ENABLED` (default: `true` when OIDC is not configured, `false`
when it is) enables the password form. Keep it disabled when OIDC works, or
at least keep login rate limiting on. There is no self-registration; create
a local admin (or reset its password) with

    mix sentinelix.create_admin --email admin@example.com

in development, `bin/create_admin` in a release (see
[Release without Docker](#release-without-docker)), or set `ADMIN_EMAIL` and
`ADMIN_PASSWORD` to create it on boot if it does not exist yet (existing
users are never modified by these variables).

## Labels

Monitors carry key/value labels such as `env=prod`, `site=helsinki`,
`service=billing` or `host=db1` instead of folders: group and filter them
along any dimension. A label's value is optional (`deprecated`).

* **Keys** are lowercase letters, digits, `_`, `.`, `-` and `/`, starting
  with a letter or digit, up to 63 characters. Uppercase is lowercased.
* **Values** are letters, digits, `_`, `.`, `-`, `/`, `:` and `@`, up to
  255 characters (so hostnames, IPv6 addresses and emails fit). Values keep
  their case and are matched exactly.
* Each key appears at most once per monitor, at most 64 labels.

Edit them in the monitor form, which suggests the keys and values already in
use. The dashboard filters by a label (pick it in the label filter or click
a label badge: `/?label=env=prod`; a bare key like `/?label=env` matches any
value), and the dashboard and monitor list search also matches labels
written as `key=value`.

Tags of earlier versions became labels without a value, normalized to the
key rules (`Web Server` became `web-server`); tags written as `key=value`
kept their value. Dashboard links with `?tag=` keep working.

## Cloning monitors

**Clone** on a monitor's page or in the monitor list opens the new-monitor
form prefilled with the monitor's type, settings, schedule, description,
labels and notification channels, named "<name> (copy)". Change what
differs (e.g. the host and the `host` label) and create it; the original is
not changed.

* **Secrets are not copied.** A PostgreSQL monitor's password has to be
  entered again: the clone can't be saved without it if the original has
  one.
* Push monitors get a new push token (the original's keeps working for the
  original).
* Maintenance windows and status pages are not copied; add the new monitor
  to them separately.

## PostgreSQL monitors

A PostgreSQL monitor logs in to a server, runs a query and optionally checks
its result and the replication status – a step past "the port is open".

* **Connection:** host, port, database, username and password, and the SSL
  mode: *require* (the default: encrypted, certificate not verified),
  *verify-full* (certificate chain checked against a CA certificate you
  paste, or the system CAs, and the hostname checked) or *disable*. Every
  check opens one fresh connection and closes it afterwards, so a working
  login is part of what is checked. The password is encrypted in the
  database like notification channel secrets and never shown again (leave
  the field blank to keep it). [Clones](#cloning-monitors) don't copy it.
* **Query:** a single statement, by default `SELECT 1`. It runs in a
  **read-only transaction** (`default_transaction_read_only`), bounded by a
  `statement_timeout` of the monitor's timeout, so a mistyped `DELETE` fails
  instead of deleting anything. Optionally the first column of the first row
  is compared with an expected value (equals, does not equal, contains,
  regular expression, or numerically `<`, `<=`, `>`, `>=`), and/or the number
  of rows with an expected count:

  | Query | Expected |
  | --- | --- |
  | `SELECT count(*) FROM jobs WHERE state = 'failed' AND inserted_at > now() - interval '1 hour'` | value `<=` 0 |
  | `SELECT max(created_at) > now() - interval '10 min' FROM events` | value equals `true` |
  | `SELECT version()` | value contains `16.` |
  | `SELECT id FROM jobs WHERE state = 'stuck'` | rows equals 0 |

  Values are compared as text: `NULL`, `true`/`false`, numbers as written,
  timestamps in ISO 8601, binary data as `\x…` hex (cast UUIDs to `text`).
* **Replication:** *primary* requires the server not to be in recovery and at
  least *minimum standbys* streaming WAL senders, and warns about inactive
  replication slots (they retain WAL until the disk fills up). *Standby*
  requires the server to be in recovery with a streaming WAL receiver. Both
  are role assertions: after a failover the monitor goes down. Replication
  lag (seconds and/or bytes) above the warning threshold raises a warning,
  above the critical threshold it is down. Needs PostgreSQL 10 or newer.

Use a dedicated low-privilege role; `pg_monitor` is only needed for the
replication check (without it the status can't be read and the monitor
reports "insufficient privileges"):

```sql
CREATE ROLE sentinelix_monitor LOGIN PASSWORD '...';
GRANT pg_monitor TO sentinelix_monitor;  -- only for replication checks
-- and for custom queries, e.g.:
GRANT SELECT ON jobs TO sentinelix_monitor;
```

The server must allow the login from Sentinelix' address in `pg_hba.conf`,
e.g. `hostssl app sentinelix_monitor 192.0.2.10/32 scram-sha-256` (`hostssl`
matches the default SSL mode *require*). For replication checks on standbys,
the role is replicated from the primary; their `pg_hba.conf` needs the entry
too.

## Status pages

Status pages are managed at `/status-pages`. A page has a slug, title,
optional description and footer, and ordered groups of monitors; once
*published* it is served without authentication at `/status/<slug>`
(unpublished pages and unknown slugs are a 404). It shows an overall status
banner, each monitor's current status with 90-day daily uptime bars, active
maintenance and the incidents of the last 7 days, and updates live.

By default only a monitor's name and status are shown. Enable *show details*
on a page to also show monitor targets (URLs, hosts) and check and incident
messages – only do that if they may be public.

## Health check and metrics

`GET /healthz` needs no authentication and is meant for Docker/Kubernetes
health checks: it responds `200 {"status": "ok", "db": "ok"}` when the
database answers and `503 {"status": "error", "db": "error"}` otherwise.

`GET /metrics` serves Prometheus metrics. It is **disabled (404) unless
`METRICS_TOKEN` is set**; with it set, requests must send
`Authorization: Bearer <METRICS_TOKEN>` (401 otherwise):

```yaml
scrape_configs:
  - job_name: sentinelix
    scheme: https
    authorization:
      credentials: <METRICS_TOKEN>
    static_configs:
      - targets: ["sentinelix.example.com"]
```

Per-monitor gauges (labels `monitor_id`, `monitor` (name) and `type`) are
computed at scrape time, so they are present right after boot and vanish when
a monitor is deleted:

| Metric | Meaning |
| --- | --- |
| `sentinelix_monitor_up` | 1 up, 0 down; absent while pending, in maintenance or disabled |
| `sentinelix_monitor_status{status="up\|down\|pending\|maintenance"}` | 1 for the current status (enabled monitors) |
| `sentinelix_monitor_enabled` | 1 enabled, 0 paused |
| `sentinelix_monitor_warning` | 1 while a check reports a warning (e.g. certificate close to expiry) |
| `sentinelix_monitor_response_time_ms` | response time of the latest check |
| `sentinelix_monitor_last_check_timestamp_seconds` | Unix time of the latest check |
| `sentinelix_monitor_cert_days_remaining` | days until the certificate expires (certificate checks) |
| `sentinelix_monitor_labels` | always 1; the monitor's [labels](#labels) as `label_<key>="<value>"` |

Monitor labels are only on `sentinelix_monitor_labels`, not on every gauge:
user-defined labels would multiply the number of series and change them
whenever a label is edited. Keys become `label_<key>` with characters other
than `a-z`, `0-9` and `_` replaced by `_`. Join them in PromQL where needed:

```promql
sentinelix_monitor_up * on (monitor_id) group_left (label_env) sentinelix_monitor_labels
```

Besides these, `/metrics` exports check counts and durations
(`sentinelix_checks_total`, `sentinelix_check_duration_milliseconds`,
`sentinelix_monitor_status_changes_total`), Phoenix request and Ecto query
metrics and BEAM VM metrics (`vm_*`).

## Notifications

Notification channels are managed at `/settings/notifications` (email,
generic webhook, Slack, Discord, Telegram, ntfy, Gotify). A channel is sent
to when a monitor it is attached to goes down, recovers, or raises/clears a
warning (e.g. a TLS certificate close to expiry). Channels marked *default*
are attached to new monitors automatically; the monitors of a channel can be
chosen on its edit page. Failed sends are retried (3 attempts, exponential
backoff).

* Channel configs (tokens, webhook URLs) are encrypted in the database with a
  key derived from `SECRET_KEY_BASE` and are never shown again in the UI
  (leave a secret field blank to keep it). Changing `SECRET_KEY_BASE` makes
  stored configs unreadable, so channels must then be set up again.
* Email is sent over SMTP (`SMTP_*`, see [Email](#email)) from
  `NOTIFICATIONS_EMAIL_FROM`, e.g. `Sentinelix <alerts@example.com>`.
* The last notified state per monitor is persisted, so restarts (monitor
  edits, deploys) don't re-send notifications for monitors that are already
  down or warned about.

## Maintenance windows

Maintenance windows are managed at `/maintenance`. A window is one-off (start
and end) or recurring (daily, or weekly on chosen weekdays, at a start time
for a duration), in a named time zone (IANA, e.g. `Europe/Oslo`; daylight
saving time is handled; new windows default to `DEFAULT_TIMEZONE`), and
applies to selected monitors or to all monitors.

* During a window checks keep running, but results are recorded as
  `maintenance`: the monitor's status doesn't change, no incidents are opened
  and no notifications are sent. Maintenance results don't count towards
  uptime.
* After the window normal evaluation resumes with the next check: a monitor
  that is down then alerts as usual (unless its outage was already notified
  before the window).
* Push monitors: pushes received and pushes missed during a window are both
  recorded as `maintenance`. A push still missing after the window is reported
  by the next deadline check.
* Monitors in an active window get a *Maintenance* badge on the dashboard and
  the monitor pages.

## Data retention

Raw check results are rolled up into hourly statistics every 5 minutes.
Raw results older than `RETENTION_DAYS` (default 90) and rollups older than
`ROLLUP_RETENTION_DAYS` (default 365) are deleted hourly; 0 keeps them
forever. Uptime and response time statistics for long windows are computed
from the rollups.

## Development

Requirements: Elixir 1.19.4 / Erlang 28.3 (see `.tool-versions`, e.g. with
asdf) and PostgreSQL.

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.
Create a local admin with `mix sentinelix.create_admin --email you@example.com`.

### Configuration

`config/dev.exs` reads the database connection from `PGHOST`, `PGPORT`,
`PGUSER`, `PGPASSWORD` and `PGDATABASE` (defaults: `localhost`, `5432`,
`postgres`, `postgres`, `sentinelix_dev`). `PORT` overrides the HTTP port.
The authentication, notification, rate limiting and retention variables above
work in development too; emails are shown at `/dev/mailbox`.

For permanent, machine-specific settings create `config/dev.local.exs`
(gitignored), which is imported at the end of `config/dev.exs`:

```elixir
import Config

config :sentinelix, Sentinelix.Repo,
  hostname: "db.example.internal",
  username: "sentinelix",
  password: "secret"

config :sentinelix, SentinelixWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: 4012]
```

### Tests

Tests use the same `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD` variables (or a full
`TEST_DATABASE_URL`) and the database `sentinelix_test<MIX_TEST_PARTITION>`.
A gitignored `config/test.local.exs` can be used for local overrides.

    PGHOST=db.example.internal PGUSER=sentinelix PGPASSWORD=secret mix test

The PostgreSQL check tests connect to the same server with their own
connections (outside the SQL sandbox). The test role needs no special
privileges; the replication tests adapt their expectations to whether it can
read the replication status (superuser or `pg_monitor`).

Before committing, run `mix precommit` (compile with warnings as errors,
unlock unused deps, check formatting, Credo, run the tests). CI
(`.forgejo/workflows/ci.yml`) runs the same checks plus `mix hex.audit` and
`mix deps.audit`.

## Architecture

```
Sentinelix.Supervisor
├── SentinelixWeb.Telemetry, Sentinelix.Repo, Phoenix.PubSub, Finch
├── Sentinelix.RateLimit                 login / push rate limits (ETS)
├── OIDC provider configuration worker   (when OIDC is configured)
├── Sentinelix.Notifications.Supervisor  dispatcher + delivery tasks
├── Sentinelix.Maintenance.Cache         active maintenance windows
├── Sentinelix.Monitoring.Supervisor     the monitoring engine
│   ├── Registry                         workers by monitor id
│   ├── Task.Supervisor                  check runs
│   ├── DynamicSupervisor                one Monitoring.Worker per enabled monitor
│   └── Monitoring.Manager               starts/stops workers on monitor changes
├── Sentinelix.Stats.Scheduler           hourly rollups and pruning
└── SentinelixWeb.Endpoint
```

* **`Sentinelix.Monitoring`** – the context for monitors (with per-type
  settings and labels), check results and incidents.
* **Engine** – each `Monitoring.Worker` runs its monitor's check on its
  interval (with retries before a monitor is considered down), stores the
  result, opens/resolves incidents and broadcasts events over PubSub
  (`"monitors"`, `"monitor:<id>"`, `"status_changes"`) and telemetry.
* **Checks** – modules implementing `Sentinelix.Checks.Check`
  (`run(monitor) :: {:up | :down, details}`), registered per monitor type in
  `Sentinelix.Checks`.
* **Notifications** – `Notifications.Dispatcher` subscribes to
  `"status_changes"` and sends to the monitor's channels through provider
  modules (`Sentinelix.Notifications.Providers.*`).
* **Maintenance** – the engine asks `Sentinelix.Maintenance` after every
  check whether the monitor is in a window.
* **Stats** – `Sentinelix.Stats` answers uptime/response time queries from
  hourly rollups plus recent raw results.
* **Web** – LiveViews for the dashboard, monitors, maintenance, status pages
  and settings; controllers for login/OIDC, push, health and metrics.
  `SentinelixWeb.Plugs.ClientIP` resolves the client address behind trusted
  proxies.
