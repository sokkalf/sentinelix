defmodule Sentinelix.Repo.Migrations.AddParentToMonitors do
  use Ecto.Migration

  # Monitor dependencies: while a monitor's parent (e.g. the ping monitor of
  # its host) is down, the monitor's failures are recorded as `unreachable`
  # and don't alert. One parent per monitor; deleting the parent detaches
  # its children. Cycles are prevented by Sentinelix.Monitoring (they need a
  # recursive query); the database only rules out a monitor being its own
  # parent.
  def change do
    alter table(:monitors) do
      add :parent_id, references(:monitors, on_delete: :nilify_all)
    end

    create index(:monitors, [:parent_id])
    create constraint(:monitors, :parent_not_self, check: "parent_id <> id")

    # Unreachable results get their own counter in the hourly rollups.
    alter table(:check_stats_hourly) do
      add :unreachable_count, :integer, null: false, default: 0
    end
  end
end
