defmodule Sentinelix.Repo.Migrations.CreateMonitorEvents do
  use Ecto.Migration

  def change do
    # Optional per-monitor token for POST /api/v1/events/:token
    # (Sentinelix.Monitoring.Events). Only grants appending events.
    alter table(:monitors) do
      add :event_token, :string
    end

    create unique_index(:monitors, [:event_token])

    # Events posted by external systems: shown in the monitor's timeline,
    # pruned with the check results.
    create table(:monitor_events) do
      add :monitor_id, references(:monitors, on_delete: :delete_all), null: false
      add :occurred_at, :utc_datetime_usec, null: false
      # info, warning or ok
      add :severity, :string, null: false
      # The warning a warning or ok event raises or clears ("" without a key).
      add :key, :string
      add :title, :text, null: false
      add :message, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:monitor_events, [:monitor_id, "occurred_at DESC"],
             name: :monitor_events_monitor_id_occurred_at_index
           )

    # The active warnings raised by events: at most one per monitor and key.
    # While a monitor has one, an up check makes it `warning`.
    create table(:monitor_warnings) do
      add :monitor_id, references(:monitors, on_delete: :delete_all), null: false
      add :key, :string, null: false, default: ""
      add :title, :text, null: false
      add :message, :text
      add :raised_at, :utc_datetime_usec, null: false
      # nil: until cleared.
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:monitor_warnings, [:monitor_id, :key])
  end
end
