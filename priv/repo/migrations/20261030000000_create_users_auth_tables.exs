defmodule Sentinelix.Repo.Migrations.CreateUsersAuthTables do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string
      add :name, :string

      # Users signing in through OpenID Connect are identified by issuer + subject,
      # never by email (emails can change or be reassigned at the IdP).
      add :oidc_issuer, :string
      add :oidc_subject, :string

      # Only set for local (break-glass) users.
      add :hashed_password, :string

      add :last_login_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:oidc_issuer, :oidc_subject])

    create unique_index(:users, ["lower(email)"],
             where: "hashed_password IS NOT NULL",
             name: :users_local_email_index
           )

    create constraint(:users, :users_identity_present,
             check:
               "(oidc_issuer IS NOT NULL AND oidc_subject IS NOT NULL) OR hashed_password IS NOT NULL"
           )

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      # The raw ID token of an OIDC login, kept for RP-initiated logout (id_token_hint).
      add :oidc_id_token, :text
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
  end
end
