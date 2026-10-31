defmodule Sentinelix.Repo.Migrations.CreateDisplayTokens do
  use Ecto.Migration

  def change do
    # Wall/kiosk display tokens (Sentinelix.DisplayTokens): read-only access
    # to some saved views without a user session.
    create table(:display_tokens) do
      # The creator; the token shows only views they see, and goes with them.
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string
      # SHA-256 of the token; the token itself is only shown once.
      add :token_hash, :binary, null: false
      # Seconds between views on the display, nil: no rotation.
      add :rotate_seconds, :integer
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:display_tokens, [:token_hash])
    create index(:display_tokens, [:user_id])

    # The views of a token, in the order the display shows them.
    create table(:display_token_views) do
      add :display_token_id, references(:display_tokens, on_delete: :delete_all), null: false
      add :saved_view_id, references(:saved_views, on_delete: :delete_all), null: false
      add :position, :integer, null: false, default: 0
    end

    create unique_index(:display_token_views, [:display_token_id, :saved_view_id])
    create index(:display_token_views, [:saved_view_id])
  end
end
