defmodule Sentinelix.Repo.Migrations.CreateMaintenanceWindows do
  use Ecto.Migration

  def change do
    create table(:maintenance_windows) do
      add :title, :string, null: false
      add :description, :text
      add :enabled, :boolean, null: false, default: true
      # Applies to every monitor (including ones created later) instead of
      # the monitors in maintenance_window_monitors.
      add :all_monitors, :boolean, null: false, default: false
      add :timezone, :string, null: false, default: "Etc/UTC"
      # once | daily | weekly
      add :recurrence, :string, null: false, default: "once"
      # One-off windows: the window. Recurring windows: optional bounds
      # (effective from / until).
      add :starts_at, :utc_datetime
      add :ends_at, :utc_datetime
      # Recurring windows: local start time in `timezone`, duration and,
      # for weekly windows, the ISO weekdays (1 = Monday .. 7 = Sunday).
      add :start_time, :time
      add :duration_minutes, :integer
      add :weekdays, {:array, :integer}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create table(:maintenance_window_monitors, primary_key: false) do
      add :maintenance_window_id, references(:maintenance_windows, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :monitor_id, references(:monitors, on_delete: :delete_all),
        null: false,
        primary_key: true
    end

    create index(:maintenance_window_monitors, [:monitor_id])
  end
end
