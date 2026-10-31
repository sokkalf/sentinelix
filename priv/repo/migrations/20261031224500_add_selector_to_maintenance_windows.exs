defmodule Sentinelix.Repo.Migrations.AddSelectorToMaintenanceWindows do
  use Ecto.Migration

  def change do
    alter table(:maintenance_windows) do
      # A label selector (Sentinelix.Monitoring.Selector, normalized): the
      # window also applies to every monitor matching it, including ones
      # created or relabeled later. "" for none.
      add :selector, :text, null: false, default: ""
    end
  end
end
