defmodule Sentinelix.Repo.Migrations.CreateMonitors do
  use Ecto.Migration

  def change do
    create table(:monitors) do
      add :name, :string, null: false
      # Stored as a plain string (not a Postgres enum) so new check types can
      # be added without a migration. Valid values live in Monitoring.Monitor.
      add :type, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :interval_seconds, :integer, null: false, default: 60
      add :retry_interval_seconds, :integer, null: false, default: 60
      add :max_retries, :integer, null: false, default: 0
      add :timeout_ms, :integer, null: false, default: 30_000
      add :settings, :map, null: false, default: fragment("'{}'::jsonb")
      add :description, :text
      add :tags, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create constraint(:monitors, :interval_seconds_min, check: "interval_seconds >= 20")

    create constraint(:monitors, :retry_interval_seconds_min,
             check: "retry_interval_seconds >= 20"
           )

    create constraint(:monitors, :max_retries_non_negative, check: "max_retries >= 0")
    create constraint(:monitors, :timeout_ms_positive, check: "timeout_ms > 0")

    # Push monitors are looked up by token on every heartbeat.
    create unique_index(:monitors, ["(settings->>'push_token')"],
             name: :monitors_push_token_index,
             where: "type = 'push'"
           )
  end
end
