defmodule Sentinelix.Repo.Migrations.CreateNotificationChannels do
  use Ecto.Migration

  def change do
    create table(:notification_channels) do
      add :name, :string, null: false
      add :type, :string, null: false
      # Provider configuration as JSON, encrypted with a key derived from
      # SECRET_KEY_BASE (see Sentinelix.Notifications.EncryptedMap).
      add :config, :binary, null: false
      add :enabled, :boolean, null: false, default: true
      add :default, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create table(:monitor_notification_channels, primary_key: false) do
      add :monitor_id, references(:monitors, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :channel_id, references(:notification_channels, on_delete: :delete_all),
        null: false,
        primary_key: true
    end

    create index(:monitor_notification_channels, [:channel_id])

    # What has last been notified per monitor, so that worker restarts
    # (monitor edits, app reboots) don't re-send notifications.
    create table(:notification_states, primary_key: false) do
      add :monitor_id, references(:monitors, on_delete: :delete_all), primary_key: true
      add :status, :string
      add :warning, :boolean, null: false, default: false

      timestamps(type: :utc_datetime, inserted_at: false)
    end
  end
end
