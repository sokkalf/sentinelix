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
  group and filter them, plus automatic `type` and `host` labels.
* **Selectors** such as `env=prod, site in (oslo,helsinki), status=down`
  filter the dashboard and the monitor list.
* **Grouping:** group the dashboard by any label (`service`, then `site`)
  with live group summaries; groups with problems come first, expanded.
* **Layouts:** a list, a compact grid of status tiles (hundreds of monitors
  on one screen), or a matrix of two labels (`service` × `site`) that shows
  at a glance whether a problem is everywhere or only in one place.
* **Saved views:** name a filtered, grouped dashboard and find it in the
  sidebar; keep it personal, share it with everyone or with your OIDC
  groups, and pick one as your default dashboard.
* **Wall displays:** saved views full screen on a TV or office screen, with a
  revocable display token instead of a login, rotating through several
  views; names and statuses only.
* **Cloning:** "same checks as db1, but for db2" – copy a monitor's
  settings, labels and notification channels into a new one.
* **Bulk actions** in the monitor list: label, pause, resume, attach
  notification channels to or delete many monitors at once.
* **Notifications** by email, generic webhook, Slack, Discord, Telegram,
  ntfy and Gotify, on down, recovery and warnings, routed per
  monitor or by selector (`env=prod` → ntfy).
* **Maintenance windows** (one-off or recurring, time zone aware) that
  suppress alerts.
* **Dependencies:** while a host's ping monitor is down, the monitors on
  that host are *unreachable* and stay quiet instead of all alerting.
* **Events:** external systems (Patroni callbacks, a disk space script)
  post events to any monitor; they show in its timeline, and a `warning`
  event puts the monitor in an amber *warning* state until it is cleared.
* **Public status pages** at `/status/<slug>`.
* **Import and export** of monitors as YAML, to keep a large setup in git:
  from the monitor list, a mix task or a release command, with a dry run.
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
| `OIDC_GROUPS_CLAIM` | Claim with the user's groups (default `groups`; dotted paths such as `realm_access.roles` work), for the allow-list and [saved views](#saved-views) |
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

### Reverse proxy, push endpoint and wall displays

| Variable | Description |
| --- | --- |
| `TRUSTED_PROXIES` | Comma separated IP addresses / CIDR ranges of reverse proxies whose `X-Forwarded-For` header is trusted, e.g. `127.0.0.1,::1,172.16.0.0/12` |
| `PUSH_RATE_LIMIT` | Push endpoint requests per minute and client IP (default 300, 0 disables) |
| `EVENTS_RATE_LIMIT` | [Events](#events-and-warnings) posted per minute and client IP (default 120, 0 disables) |
| `WALL_RATE_LIMIT` | [Wall display](#wall-displays) page loads and (re)connects per minute and client IP (default 60, 0 disables) |

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
* `/api/v1/events/<token>` – [monitor events](#events-and-warnings)
* `/wall/<token>` – [wall displays](#wall-displays) (and `/live`, `/assets`)
* `/healthz` – health check, `/metrics` – Prometheus (bearer token)
* `/login`, `/auth/oidc`, `/auth/oidc/callback` – sign-in

Everything else requires a session.

### Rate limiting

Password logins (`POST /login`), the push endpoint (`/api/push/<token>`),
the event endpoint (`/api/v1/events/<token>`) and wall displays
(`/wall/<token>`, page loads and LiveView (re)connects) are rate limited
per client IP in fixed one-minute windows (`LOGIN_RATE_LIMIT`, default 10;
`PUSH_RATE_LIMIT`, default 300; `EVENTS_RATE_LIMIT`, default 120;
`WALL_RATE_LIMIT`, default 60). Requests over the limit get
`429 Too Many Requests` with a `Retry-After` header (a wall display reloads
itself when it may again). The counters live in memory (ETS) and are per
node. Many wall displays behind one address (NAT) share a bucket: raise
`WALL_RATE_LIMIT` if they reconnect at the same time, e.g. after a restart.

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
    include the groups claim, e.g. `groups`, if you use `OIDC_ALLOWED_GROUPS`
    or share saved views with groups)

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

The user's groups are stored at every login, replacing the ones from the
last login, so [saved views](#saved-views) can be shared with groups. A
change at the IdP takes effect at the user's next login. Local users have
no groups.

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
`service=billing` or `team=db` instead of folders: group and filter them
along any dimension. A label's value is optional (`deprecated`).

* **Keys** are lowercase letters, digits, `_`, `.`, `-` and `/`, starting
  with a letter or digit, up to 63 characters. Uppercase is lowercased.
* **Values** are letters, digits, `_`, `.`, `-`, `/`, `:` and `@`, up to
  255 characters (so hostnames, IPv6 addresses and emails fit). Values keep
  their case and are matched exactly.
* Each key appears at most once per monitor, at most 64 labels.

Edit them in the monitor form, which suggests the keys and values already in
use. The dashboard and the monitor list filter by labels with
[selectors](#selectors); clicking a label badge adds it to the selector.

### Automatic labels

Every monitor also has read-only automatic labels, derived from its
settings whenever it is saved:

* `type`: the monitor type (`http`, `keyword`, `tcp`, `ping`, `dns`,
  `cert`, `push` or `postgres`).
* `host`: the host it checks: the host of the URL (HTTP and keyword
  monitors) or the hostname or IP address (TCP, ping, DNS, certificate and
  PostgreSQL monitors), lowercased, without port or trailing dot
  (`https://WWW.Example.com:8443/` gives `host=www.example.com`). Push
  monitors have none.

Selectors use them like your own labels (`type=tcp`,
`host=db1.example.com`), and they appear as muted, dashed badges on the
monitor page and in the monitor form. `type` and `host` are reserved: your
own labels can't use them. Labels named `type` or `host` from before
automatic labels were dropped where they equalled the automatic one and
renamed to `user/type` and `user/host` otherwise.

Tags of earlier versions became labels without a value, normalized to the
key rules (`Web Server` became `web-server`); tags written as `key=value`
kept their value. Dashboard links with `?tag=` keep working.

## Selectors

A selector picks monitors by their labels (your own and the automatic
ones), name and status. It is a comma-separated list of terms that all have
to match, much like Kubernetes label selectors:

```
env=prod, site in (oslo,helsinki), service!=legacy, !deprecated, host
```

| Term | Matches monitors |
|------|------------------|
| `key` | with the label `key`, whatever its value |
| `!key` | without the label `key` |
| `key=value` (or `==`) | with exactly this value (case-sensitive) |
| `key!=value` | without the label, or with another value |
| `key in (a,b)` | whose value is one of these |
| `key notin (a,b)` | without the label, or with none of these values |
| `key~text` | whose value contains the text (case-insensitive) |
| `key!~text` | without the label, or whose value doesn't contain the text |

Two keys are pseudo-labels instead of labels (so labels of your own named
`status` or `name` can't be selected):

* `status`: the current status, `up`, `down`, `pending`, `maintenance`,
  `unreachable`, `warning` or `paused` (with `=`, `!=`, `in` and `notin`): `status=down`,
  `status in (down,pending)`.
* `name`: the monitor's name, with any operator that takes a value:
  `name~api` (name contains "api", ignoring case), `name="Web 1"`.

Spaces around operators and commas don't matter, keys are lowercased, and
an empty selector matches every monitor. Values need no quotes, except for
names with spaces or one of `, ( ) " = ! ~` in them: `name~"web 1"`
(`\"` and `\\` inside quotes). A term with an error (`env=`, an unknown
status) is shown below the input with its column.

Examples:

* `env=prod, status=down`: production monitors that are down.
* `type=http, host~example.com`: HTTP monitors of hosts under example.com.
* `team=db, !deprecated, status!=paused`: the db team's active monitors.
* `site notin (oslo)`: everything not in Oslo, including monitors without a
  `site` label.

On the **dashboard** the selector is in the URL
(`/?selector=env%3Dprod%2C%20status%3Ddown`), so a filtered dashboard can be
bookmarked and shared. The status counters toggle a `status=` term, label
badges add their label, and the input suggests the keys and values in use,
automatic labels included. Older dashboard links keep working: `?q=web`
becomes `name~web`, `?status=down` `status=down`, and `?label=env=prod` or
`?tag=legacy` that label. The **monitor list** takes the same selector
(`/monitors?selector=...`); bulk actions apply to the monitors it shows.

## Grouping the dashboard

With many monitors, group the dashboard by a label key (*Group by* next to
the selector), and optionally by a second one to nest groups:
`service`, then `site`. Automatic labels work too (`type`, `host`).
Monitors without the key go to a *(none)* group.

Each group header shows the worst status of its monitors, how many are up
(`12/14 up`), how many are down, unreachable, pending, warning, in
maintenance or paused, and the group's 24h uptime (over all checks of its monitors, so
monitors that check more often weigh more). Headers update live.

* **Problems first** (the default sort): groups with a monitor that is down,
  unreachable, pending or warning come first, the worst first, and are expanded.
  Groups without problems are collapsed and sorted by name. *By name* sorts
  all groups by name.
* Click a header to expand or collapse a group, or use *Expand all* and
  *Collapse all*. Your choice sticks for the browser session (reloads
  included) until the group's state changes: a group you collapsed while
  it was red expands again when it turns red after recovering, and a group
  you expanded while green collapses once it has had a problem and
  recovered.

Group-by and sort are part of the dashboard URL along with the selector
(`/?selector=env%3Dprod&group=service,site&sort=name`), so a grouped
dashboard can be bookmarked and shared. A collapsed group renders no rows,
which keeps dashboards with hundreds of monitors light.

### Layouts

*Layout* (next to the selector) switches how the dashboard shows the
monitors; it is part of the URL too (`&layout=grid`):

* **List** (the default): a row per monitor with its labels, heartbeats,
  24h uptime and latest response time.
* **Grid**: a small tile per monitor, colored by its status, so 200 or more
  fit on one screen. Hover over or tab to a tile for its status, last
  response time and 24h uptime; click it for the monitor's page. The grid
  is grouped, sorted and collapsed like the list.
* **Matrix**: the first group-by key as rows and the second as columns
  (*Rows by* `service`, *columns by* `site`). Each cell shows the worst
  status of its monitors and how many there are: `1/3` means one of three
  is in that state, `3` that all three are up; an empty cell has no
  monitors. Hover over or tab to a cell for its counts per status and its
  uptime. Click a cell, or a row or column header, to list its monitors
  (the selector gets `service=api, site=helsinki`; the browser's back
  button returns to the matrix). Rows follow the sort, columns are sorted
  by name so they stay in place. Until two keys are chosen, the matrix asks
  for them.

Statuses don't rely on color alone: tiles and cells also have an icon per
status (a check for up, a cross for down, a "no" sign for unreachable, a
clock for pending, a wrench for maintenance, a warning sign for warning, a
pause sign for paused),
unreachable and paused have a dashed border, and screen readers get the
status as text.

## Saved views

A saved view is a dashboard URL with a name: the selector, grouping, sort
and layout. Set up the dashboard, use **Save view**, give it a name and
choose who sees it:

* **Personal**: only you.
* **Shared**: all users.
* **Groups**: users in any of the OIDC groups you choose (see
  [OpenID Connect](#openid-connect)). You can only choose groups you are a
  member of; local users have none.

Saved views are listed in the sidebar under *Dashboard*, your own first, in
your order, then the ones others share with you, by name. A view is shown
at `/views/<slug>`; the slug comes from the name when the view is saved and
stays when it's renamed, so links and bookmarks keep working. Changing the
filters on a saved view keeps you on it (`/views/prod?group=site`, marked
*changed*): **Update view** stores the change, **Reset** goes back and
**Save as new view** saves a copy.

**Make default** (the star) shows a view at `/` instead of the plain
dashboard; `/?selector=` (*Show all monitors*) still shows all monitors.
*Manage views* (`/views`) renames, reorders and deletes your views, changes
who sees them and picks your default.

Only the owner of a view can change or delete it, also for shared views:
there is no admin role yet (if roles are added, admins should be able to
manage shared views). Deleting a user deletes their views. A stored
selector keeps working when labels disappear (it then matches nothing);
one that no longer parses is shown with its error.

## Wall displays

A wall display shows saved views full screen on a TV, an office screen or a
kiosk browser, without a logged in account: large status tiles readable
from across the room, no navigation, light or dark (the theme toggle in the
corner, or the system setting).

Create one under **Settings → Wall displays** (`/settings/displays`, also
linked from *Manage views*): pick one or more views you see, optionally a
number of seconds per view to rotate through them, a name and an expiry.
Sentinelix then shows the display's URL, `https://<host>/wall/<token>`,
**once**: only a hash of the token is stored, so a lost URL can't be shown
again. Revoke the display and create a new one instead.

How a view is shown depends on its layout: *list* views get large tiles
with status, response time and 24h uptime, *grid* views small tiles (many
monitors on one screen), *matrix* views a large matrix. Grouped views show
their groups by the label values (`oslo`). The header shows how many
monitors are down, unreachable, pending or in maintenance, or "All up".

What a display shows, and doesn't:

* Only monitor names, statuses, response times and uptime, the group
  values or matrix rows/columns of the view, and warning/maintenance icons.
  Never targets, settings, labels, selectors, descriptions, check messages
  or maintenance titles. Nothing on it links anywhere.
* Only the display's views that **its creator sees at the time**: when a
  view is made personal by its owner or scoped to groups the creator has
  left (as of their next login), the display stops showing it (and shows
  it again if they see it again). Deleting a view removes it from its
  displays; deleting the user deletes their displays.
* Users manage only their own displays.

Revoking a display or deleting its creator disconnects open screens right
away, an expired display within 30 seconds; they then show the same `404 Not Found` as any
unknown or mistyped token, so a token can't be told apart from a revoked
one. Displays update live and reconnect by themselves after a network loss
or a restart (the token is in the URL, and every reconnect checks it
again). While disconnected they show a *Connection lost* banner and dim
the tiles, so a stale screen isn't mistaken for a green one.

The token is part of the URL, which keeps kiosk setups simple (a bookmark,
no cookies or logins to expire) but means it can show up where URLs do:

* Sentinelix doesn't log it: requests are logged as `GET /wall/[FILTERED]`,
  and `token` parameters are filtered from debug logs.
* Pages send `Referrer-Policy: no-referrer` (and `Cache-Control: no-store`,
  `X-Robots-Tag: noindex`), so the URL isn't passed on as a referrer.
* Reverse proxy access logs and the browser's history do contain it: turn
  off or filter access logs for `/wall/` at the proxy if that matters, and
  treat the URL like a password.

## Cloning monitors

**Clone** on a monitor's page or in the monitor list opens the new-monitor
form prefilled with the monitor's type, settings, schedule, description,
labels, parent and notification channels, named "<name> (copy)". Change what
differs (e.g. the host and the `host` label) and create it; the original is
not changed.

* **Secrets are not copied.** A PostgreSQL monitor's password has to be
  entered again: the clone can't be saved without it if the original has
  one.
* Push monitors get a new push token (the original's keeps working for the
  original).
* Maintenance windows and status pages are not copied; add the new monitor
  to them separately (windows with a selector pick it up if its labels
  match).

## Bulk actions

The monitor list (`/monitors`) changes many monitors at once. Select
monitors with the checkboxes, or all monitors matching the current
[selector](#selectors) with the checkbox in the table header (or *Select
all*). Then:

* **Labels:** enter one or more labels separated by spaces or commas and
  click *Add* (`env=prod` sets the value, replacing another value of `env`)
  or keys and click *Remove* (`env` removes the label whatever its value).
* **Pause** or **Resume** the monitors.
* **Attach** or **Detach** a notification channel (in addition to the
  channels the monitors already have).
* **Delete** the monitors with their history, after a confirmation that
  shows how many.

Each action changes all selected monitors or, if one of them can't be
changed (e.g. it would get more than 64 labels), none. The checks of the
changed monitors restart with the new configuration, as after editing a
monitor. Only monitors that are shown can be selected: narrowing the selector
deselects the monitors it hides, and monitors that start matching are not
selected automatically.

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

A group is either a **fixed list** of monitors or chooses them by
**selector** (see [Selectors](#selectors)), e.g. `env=prod, service in
(web,api)`: monitors that are created, relabelled or renamed so that they
match join the group (and the published page, live) automatically, and
leave it when they no longer match. Group selectors may use labels and
names but not `status=`, so services don't vanish from the page when they
go down. A selector group needs a selector; there is no "all monitors"
group, so a page never publishes every monitor by accident (write a
selector such as `type` for that).

In a selector group the matches are ordered by name. Monitors added to it
by hand are **pinned**: shown first, in the order you give them, even if the
selector doesn't match them (they're marked *not matched* in the editor).
Switching a group between the two kinds keeps its own monitors. While you
type a selector, the editor previews exactly which monitors the group would
show on the public page.

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
| `sentinelix_monitor_up` | 1 up (or warning), 0 down; absent while pending, in maintenance, unreachable or disabled |
| `sentinelix_monitor_status{status="up\|down\|pending\|maintenance\|unreachable\|warning"}` | 1 for the current status (enabled monitors) |
| `sentinelix_monitor_enabled` | 1 enabled, 0 paused |
| `sentinelix_monitor_warning` | 1 while a check reports a warning (e.g. certificate close to expiry) |
| `sentinelix_monitor_response_time_ms` | response time of the latest check |
| `sentinelix_monitor_last_check_timestamp_seconds` | Unix time of the latest check |
| `sentinelix_monitor_cert_days_remaining` | days until the certificate expires (certificate checks) |
| `sentinelix_monitor_labels` | always 1; the monitor's [labels](#labels), automatic ones included, as `label_<key>="<value>"` |

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
to when one of its monitors goes down, recovers, or raises/clears a warning
(a TLS certificate close to expiry, or a [warning event](#events-and-warnings)). Failed sends are retried (3
attempts, exponential backoff). Disabled channels are never sent to.

A channel's monitors are the ones **attached** to it plus the ones its
**selector** matches:

* **Attached:** check the monitors on the channel's edit page, or the
  channels in the monitor form, or use the bulk actions. Channels marked
  *default* are attached to new monitors automatically.
* **By selector:** give the channel a [selector](#selectors) to notify every
  monitor it matches, now or later: `env=prod` on an ntfy channel and
  `env=staging` on an email channel route production alerts to phones and
  staging alerts to email, without attaching anything. Selectors take label
  and name terms (`status=` can't be used: the notification itself is the
  status change). The channel's edit page marks the monitors the selector
  matches as you type.

An **empty selector routes nothing** (only the attached monitors are
notified), unlike an empty selector on the dashboard, which shows every
monitor. To route every monitor, use a label every monitor has, such as
`type`.

Routing is resolved for each notification from the monitor's labels at that
moment, so adding `env=prod` to a monitor routes its next alert to the
`env=prod` channels right away. A monitor's page lists the channels that
notify it and why (*attached*, *via selector*), and its form marks the
channels the labels being edited route to. **Send test** on a monitor's page
sends a test notification to exactly the channels a real alert would go to;
**Test** on the settings page tests a single channel.

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
applies to

* **all monitors**, including ones created later;
* **selected monitors**; or
* the monitors **matching a [selector](#selectors)** (`site=oslo`,
  `env=prod, !legacy`), plus optionally some selected ones. Membership is
  dynamic: a monitor created, relabeled (also with bulk actions) or renamed
  to match is in the window from its next check, and one that no longer
  matches leaves it. The form previews the monitors the selector matches
  now. `status` terms aren't allowed: a window chosen by status would
  change its own monitors' status.

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

## Dependencies

When a host goes away, every monitor on it fails at once. Give those
monitors a **parent** ("Depends on" in the monitor form), typically the
host's ping monitor, and only the parent alerts:

* While the parent is down, the child's failed checks are recorded as
  **unreachable**: its status doesn't change, no incident is opened and no
  notification is sent. The parent's incident covers the outage. Checks
  that succeed are recorded as up as usual.
* The parent counts as down as soon as one of its checks fails, while it is
  still retrying. If a child notices first (its retries are used up before
  the parent's next check), the parent is checked right away and the
  child checks again once it has answered, so an outage of the host
  doesn't page for the child just because the child was checked first.
* When the parent is back, its children are re-checked right away. A child
  that is still failing then goes through its retries and goes down (and
  alerts) like any other monitor.
* Dependencies chain: a child of an unreachable monitor is unreachable
  too. A paused parent doesn't suppress anything. A monitor has at most one
  parent, and cycles (also indirect ones) are rejected.
* Unreachable time **counts as downtime** in uptime statistics and on
  status pages: the service wasn't available, the parent only explains why
  and keeps the alert quiet. Status pages show such monitors as
  *Unreachable* and count them as an outage.
* Push monitors with a parent record missed or failed pushes as
  unreachable while the parent is down; they aren't re-checked when it
  comes back, the next deadline decides.

The form suggests a parent: the ping monitor (or, failing that, the TCP
monitor) with the same automatic `host` label. TCP monitors are only
suggested ping monitors, and ping monitors get no suggestion. The monitor
page shows what a monitor depends on and what depends on it, and the
dashboard counts unreachable monitors separately. Deleting a parent
detaches its children; clones keep the parent of the original.

## Events and warnings

External systems can post **events** to any monitor, whatever its type.
Generate an **event token** in the *Events* card on the monitor's page
(regenerate or revoke it there too); it is separate from a push monitor's
push token and only allows adding events to that monitor. The card shows
the URL and a `curl` example.

    POST /api/v1/events/<token>

with a form or JSON body:

| Field | |
| --- | --- |
| `title` | Required, a one-line description |
| `message` | Optional, a longer text |
| `severity` | `info` (default), `warning` or `ok`, see below |
| `key` | Which warning a `warning` or `ok` event raises or clears (default: none) |
| `ttl` | `warning` only: the warning expires after this long unless raised again, in seconds or with a unit (`90`, `30m`, `12h`, `7d`; at most 365 days) |
| *anything else* | Kept as details of the event (e.g. `action`, `role`, `cluster`, `host`) |

The answer is `201 {"ok": true, "status": "warning"}` with the monitor's
resulting status, `400` with an `error` for invalid fields, `404` for an
unknown token or a paused monitor and `429` when rate limited
(`EVENTS_RATE_LIMIT`).

A Patroni callback (`on_role_change`, `on_start`, `on_stop`, …) that records
promotions and demotions on the node's monitor:

```sh
#!/bin/sh
# patroni calls: <script> <action> <role> <cluster_name>
curl -fsS -X POST "https://sentinelix.example/api/v1/events/$TOKEN" \
  -d title="Patroni $1: $(hostname -s) is now $2" \
  -d action="$1" -d role="$2" -d cluster="$3" -d host="$(hostname -f)"
```

Events show in the monitor's *Incidents and events* timeline, with their
details folded away. What else happens depends on the severity:

* `info`: nothing, the monitor's status doesn't change.
* `warning`: raises the warning `key`. While a monitor has an active
  warning, its successful checks show it as **warning** (amber) instead of
  up, right away and until the warning is cleared. A check that fails still
  takes it down; when it recovers, it is back in warning.
* `ok`: clears the warning with the same `key`.

Use keys for independent warnings, e.g. `key=disk` and `key=lag`: the
monitor stays in warning until all of them are cleared. An `ok` without a
key clears the warning without a key only. Raising a warning again replaces
its title, message and ttl. Warnings with a `ttl` expire by themselves if no
`ok` arrives, so a forgotten warning doesn't stay forever, and the monitor's
page lists the active warnings with a button to clear them by hand. Expired
and cleared warnings are logged as `ok` events.

* `warning` **counts as up** for uptime and response times: the service
  works, but needs attention.
* Entering warning opens an incident and going back up resolves it, like
  going down does. Channels are notified of the warning and of its clear,
  like a certificate warning.
* Status pages show a monitor in warning as *Degraded*, without the warning
  incident or any events.
* While a monitor is in maintenance or unreachable, warnings wait for its
  next normal check.
* Events are deleted after `RETENTION_DAYS`, like raw check results, and
  with the monitor. Event tokens are not exported or copied by cloning.

## Import and export

Monitors can be exported as YAML and imported again, e.g. to keep the setup
in git, review changes as diffs, or move it to another instance.

* **Monitor list:** *Export* downloads the monitors matching the current
  selector (its label and name terms) and *Import* uploads a file, shows
  what would be created and updated, and imports it after you confirm.
* **Mix:** `mix sentinelix.export [--selector S] [--output FILE]
  [--push-tokens]` and `mix sentinelix.import FILE [--dry-run]
  [--report-missing] [--selector S]` (`FILE` can be `-` for standard
  input). A server that is already running picks up changes from the mix
  task when it restarts.
* **Release:** `bin/export_monitors` and `bin/import_monitors` take the
  same arguments, e.g. `docker compose exec app bin/import_monitors
  /data/monitors.yaml --dry-run`. The import runs inside the running server,
  so changed monitors restart right away.

```yaml
# Sentinelix monitors
version: 1
monitors:
  - name: Router
    type: ping
    enabled: true
    interval_seconds: 60
    retry_interval_seconds: 60
    max_retries: 0
    timeout_ms: 30000
    settings:
      host: "10.0.0.1"
  - name: Shop API
    type: http
    enabled: true
    interval_seconds: 30
    retry_interval_seconds: 30
    max_retries: 2
    timeout_ms: 10000
    parent: Router
    labels:
      env: prod
      legacy: ""
    channels:
      - Ops email
    settings:
      url: https://shop.example.com/health
      method: GET
```

* `version` is the format version (1); other versions are rejected.
* Monitors are matched **by name**: a monitor without a namesake is
  created, one with a namesake is updated (or reported unchanged). Names
  must be unique, in the file and among the monitors it matches; a monitor
  renamed in the file is created anew.
* Each monitor in the file is complete: what is left out gets its default
  (no labels, parent or channels, the type's default settings). `parent`
  and `channels` are names; channels must exist. Only channels attached to
  a monitor are exported, not those that reach it through notification
  routing.
* **Secrets are never exported or imported.** Updated monitors keep their
  stored secrets (e.g. a PostgreSQL password); created ones have none, so
  enter them after the import.
* **Push tokens** are credentials and are only exported with
  `--push-tokens`. A token in the file is used; without one an updated push
  monitor keeps its token and a created one gets a new token.
* Monitors that aren't in the file are never changed or deleted; the dry run
  and the import list them with `--report-missing` (or the checkbox in the
  UI), optionally only those matching `--selector`.
* An import is **all or nothing**: the whole file is checked first and every
  error is reported with its monitor and field (`monitor 3 "API":
  settings.url must be a valid http:// or https:// URL`); then everything
  is written in one transaction. Parents are set after all monitors exist,
  so their order in the file doesn't matter, and cycles are rejected.
* The YAML is parsed safely: no custom tags, no atoms, one document, at
  most 5 MB.

## Data retention

Raw check results are rolled up into hourly statistics every 5 minutes.
Raw results and [monitor events](#events-and-warnings) older than
`RETENTION_DAYS` (default 90) and rollups older than
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
├── Sentinelix.RateLimit                 login / push / events / wall rate limits (ETS)
├── OIDC provider configuration worker   (when OIDC is configured)
├── Sentinelix.Notifications.Supervisor  dispatcher + delivery tasks
├── Sentinelix.Maintenance.Cache         active maintenance windows
├── Sentinelix.Monitoring.Supervisor     the monitoring engine
│   ├── Registry                         workers by monitor id (and their reachability)
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
  `"status_changes"` and sends to the monitor's channels (attached or routed
  by selector, resolved per event) through provider modules
  (`Sentinelix.Notifications.Providers.*`).
* **Maintenance** – the engine asks `Sentinelix.Maintenance` after every
  check whether the monitor is in a window.
* **Dependencies** – every worker publishes whether its latest check
  succeeded in the engine's registry and broadcasts it to its children,
  which read their parent's state there when a check of theirs fails (see
  [Dependencies](#dependencies)).
* **Events** – `Sentinelix.Monitoring.Events` stores events and the
  active warnings they raise (per monitor and key) and tells the monitor's
  worker, which applies them to its status right away and expires warnings
  with a ttl (see [Events and warnings](#events-and-warnings)).
* **Saved views** – `Sentinelix.SavedViews` stores a view as its URL
  parameters (`Monitoring.View.to_params/1`, so new view settings need no
  migration) and checks who sees and changes it against the caller's
  `Accounts.Scope` (user and OIDC groups).
* **Wall displays** – `Sentinelix.DisplayTokens` stores display tokens
  hashed (SHA-256) with their views; `SentinelixWeb.WallAuth` rate limits
  and verifies them on every page load and mount, and
  `SentinelixWeb.WallLive` renders the views from the same live monitor
  index as the dashboard (`SentinelixWeb.MonitorIndex`), keeping only
  sanitized data in its assigns.
* **Stats** – `Sentinelix.Stats` answers uptime/response time queries from
  hourly rollups plus recent raw results.
* **Web** – LiveViews for the dashboard, monitors, maintenance, status pages
  and settings; controllers for login/OIDC, push, events, health and
  metrics.
  `SentinelixWeb.Plugs.ClientIP` resolves the client address behind trusted
  proxies.
