defmodule Sentinelix.Repo.Migrations.CreateIncidents do
  use Ecto.Migration

  def change do
    create table(:incidents) do
      add :monitor_id, references(:monitors, on_delete: :delete_all), null: false
      add :from_status, :string, null: false
      add :to_status, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec
      add :message, :text

      timestamps(type: :utc_datetime)
    end

    create index(:incidents, [:monitor_id, "started_at DESC"],
             name: :incidents_monitor_id_started_at_index
           )

    # At most one open (unresolved) incident per monitor.
    create unique_index(:incidents, [:monitor_id],
             name: :incidents_one_open_per_monitor_index,
             where: "resolved_at IS NULL"
           )

    create constraint(:incidents, :resolved_after_started,
             check: "resolved_at IS NULL OR resolved_at >= started_at"
           )
  end
end
