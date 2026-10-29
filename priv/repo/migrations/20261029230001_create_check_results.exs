defmodule Sentinelix.Repo.Migrations.CreateCheckResults do
  use Ecto.Migration

  def change do
    create table(:check_results) do
      add :monitor_id, references(:monitors, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :response_time_ms, :integer
      add :status_code, :integer
      add :message, :text
      add :checked_at, :utc_datetime_usec, null: false
    end

    create index(:check_results, [:monitor_id, "checked_at DESC"],
             name: :check_results_monitor_id_checked_at_index
           )
  end
end
