defmodule Sentinelix.Repo.Migrations.CreateCheckStatsHourly do
  use Ecto.Migration

  def change do
    # Hourly rollups of check_results, kept longer than the raw results.
    create table(:check_stats_hourly, primary_key: false) do
      add :monitor_id, references(:monitors, on_delete: :delete_all),
        null: false,
        primary_key: true

      # Start of the (UTC) hour.
      add :hour, :utc_datetime, null: false, primary_key: true
      add :up_count, :integer, null: false, default: 0
      add :down_count, :integer, null: false, default: 0
      add :pending_count, :integer, null: false, default: 0
      add :maintenance_count, :integer, null: false, default: 0
      # Response times of :up results only.
      add :response_count, :integer, null: false, default: 0
      add :avg_ms, :float
      add :min_ms, :integer
      add :max_ms, :integer
    end

    create index(:check_stats_hourly, [:hour])

    # Single-row table: results before `rolled_up_until` are covered by the
    # rollups, so stats queries read rollups before it and raw results after.
    create table(:check_stats_rollup_state, primary_key: false) do
      add :id, :smallint, primary_key: true
      add :rolled_up_until, :utc_datetime, null: false
    end

    create constraint(:check_stats_rollup_state, :single_row, check: "id = 1")
  end
end
