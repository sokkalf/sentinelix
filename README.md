# Sentinelix

A self-hosted uptime monitor built with Elixir and Phoenix.

## Development

Requirements: Elixir 1.19 / Erlang 28 (see `.tool-versions`) and PostgreSQL.

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

### Configuration

`config/dev.exs` reads the database connection from `PGHOST`, `PGPORT`,
`PGUSER`, `PGPASSWORD` and `PGDATABASE` (defaults: `localhost`, `5432`,
`postgres`, `postgres`, `sentinelix_dev`). `PORT` overrides the HTTP port.

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

Before committing, run `mix precommit` (compile with warnings as errors,
unlock unused deps, check formatting, run the tests).

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

The host is the endpoint URL (`PHX_HOST` in production). PKCE (S256) is used
automatically when the IdP supports it.

| Variable | Description |
| --- | --- |
| `OIDC_ISSUER` | Issuer URL; discovery is read from `<issuer>/.well-known/openid-configuration` |
| `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` | Client credentials |
| `OIDC_SCOPES` | Default `openid profile email` |
| `OIDC_PROVIDER_NAME` | Button label: "Sign in with ..." (default `SSO`) |
| `OIDC_GROUPS_CLAIM` | Claim with the user's groups (default `groups`; dotted paths such as `realm_access.roles` work) |
| `OIDC_ALLOWED_GROUPS` | Comma separated groups allowed to log in |
| `OIDC_ALLOWED_EMAILS` | Comma separated email addresses allowed to log in |
| `OIDC_ALLOWED_DOMAINS` | Comma separated email domains allowed to log in |

Without any `OIDC_ALLOWED_*` setting every user the IdP authenticates may log
in; otherwise a user matching any of the lists may. Claims from the userinfo
endpoint are merged into the ID token claims, so a groups claim that only the
userinfo endpoint returns works too. Users are created on their first login
and identified by issuer + subject, not by email.

### Local break-glass login

`LOCAL_AUTH_ENABLED` (default: `true` when OIDC is not configured, `false`
when it is) enables the password form. There is no self-registration; create
a local admin (or reset its password) with

    mix sentinelix.create_admin --email admin@example.com

or set `ADMIN_EMAIL` and `ADMIN_PASSWORD` to create it on boot if it does not
exist yet.
