defmodule Sentinelix.Stats.RollupTest do
  # Not async: the rollup watermark is a single row shared by all tests.
  use Sentinelix.DataCase, async: false

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring.CheckResult
  alias Sentinelix.Stats.{HourlyStat, Rollup}

  @now ~U[2026-10-30 12:30:00.000000Z]

  defp at(time), do: DateTime.new!(~D[2026-10-30], time, "Etc/UTC")

  defp result(monitor, status, checked_at, response_time_ms \\ nil) do
    check_result_fixture(monitor, %{
      status: status,
      checked_at: checked_at,
      response_time_ms: response_time_ms
    })
  end

  defp rollups do
    HourlyStat |> order_by([:monitor_id, :hour]) |> Repo.all()
  end

  setup do
    %{monitor: monitor_fixture()}
  end

  describe "run/1" do
    test "aggregates complete hours", %{monitor: monitor} do
      other = monitor_fixture()

      result(monitor, :up, at(~T[10:00:00]), 100)
      result(monitor, :up, at(~T[10:20:00]), 200)
      result(monitor, :up, at(~T[10:40:00]), 600)
      result(monitor, :down, at(~T[10:50:00]), 30_000)
      result(monitor, :pending, at(~T[10:55:00]), 30_000)
      result(monitor, :maintenance, at(~T[10:59:59.999999]))
      result(monitor, :down, at(~T[11:30:00]))
      result(other, :maintenance, at(~T[11:30:00]))
      # The current hour is not complete yet.
      result(monitor, :up, at(~T[12:00:00]), 100)

      assert Rollup.watermark() == nil
      assert {:ok, 3} = Rollup.run(now: @now)
      assert Rollup.watermark() == ~U[2026-10-30 12:00:00Z]

      monitor_id = monitor.id
      other_id = other.id

      assert [
               %HourlyStat{
                 monitor_id: ^monitor_id,
                 hour: ~U[2026-10-30 10:00:00Z],
                 up_count: 3,
                 down_count: 1,
                 pending_count: 1,
                 maintenance_count: 1,
                 response_count: 3,
                 avg_ms: 300.0,
                 min_ms: 100,
                 max_ms: 600
               },
               %HourlyStat{
                 monitor_id: ^monitor_id,
                 hour: ~U[2026-10-30 11:00:00Z],
                 up_count: 0,
                 down_count: 1,
                 response_count: 0,
                 avg_ms: nil,
                 min_ms: nil
               },
               %HourlyStat{
                 monitor_id: ^other_id,
                 hour: ~U[2026-10-30 11:00:00Z],
                 maintenance_count: 1
               }
             ] = rollups()
    end

    test "is idempotent and picks up late results of the previous hour", %{monitor: monitor} do
      result(monitor, :up, at(~T[11:10:00]), 100)
      assert {:ok, 1} = Rollup.run(now: @now)
      before = rollups()

      # Re-aggregates the last hour, with the same outcome.
      assert {:ok, 1} = Rollup.run(now: @now)
      assert rollups() == before

      # Recorded after the rollup, but belongs to the previous hour.
      result(monitor, :up, at(~T[11:50:00]), 300)
      result(monitor, :down, at(~T[12:10:00]))

      assert {:ok, 2} = Rollup.run(now: at(~T[13:01:00]))
      assert Rollup.watermark() == ~U[2026-10-30 13:00:00Z]

      assert [
               %HourlyStat{hour: ~U[2026-10-30 11:00:00Z], up_count: 2, avg_ms: 200.0},
               %HourlyStat{hour: ~U[2026-10-30 12:00:00Z], up_count: 0, down_count: 1}
             ] = rollups()
    end

    test "never moves the watermark back", %{monitor: _monitor} do
      {:ok, _} = Rollup.run(now: @now)
      {:ok, _} = Rollup.run(now: DateTime.add(@now, -3, :hour))
      assert Rollup.watermark() == ~U[2026-10-30 12:00:00Z]
    end
  end

  describe "prune/1" do
    setup %{monitor: monitor} do
      for days <- [1, 5, 10, 100, 400] do
        result(monitor, :up, DateTime.add(@now, -days, :day), 100)
      end

      :ok
    end

    test "does nothing before the first rollup" do
      assert Rollup.prune(now: @now, retention_days: 2, rollup_retention_days: 2) ==
               %{results: 0, rollups: 0}
    end

    test "deletes raw results and rollups past their retention" do
      {:ok, 5} = Rollup.run(now: @now)

      assert Rollup.prune(now: @now, retention_days: 7, rollup_retention_days: 365) ==
               %{results: 3, rollups: 1}

      assert Repo.aggregate(CheckResult, :count) == 2
      assert length(rollups()) == 4
    end

    test "uses the configured retention" do
      {:ok, 5} = Rollup.run(now: @now)

      # config.exs: 90 days raw, 365 days rollups.
      assert Rollup.prune(now: @now) == %{results: 2, rollups: 1}
    end

    test "keeps data forever with a retention of 0 or nil" do
      {:ok, 5} = Rollup.run(now: @now)

      assert Rollup.prune(now: @now, retention_days: 0, rollup_retention_days: nil) ==
               %{results: 0, rollups: 0}
    end

    test "never deletes results that are not rolled up" do
      # Watermark 20 days ago: only results before it are covered.
      {:ok, _} = Rollup.run(now: DateTime.add(@now, -20, :day))

      assert %{results: 2} = Rollup.prune(now: @now, retention_days: 7)
      assert Repo.aggregate(CheckResult, :count) == 3
    end

    test "deletes in batches", %{monitor: monitor} do
      for i <- 1..25, do: result(monitor, :up, DateTime.add(@now, -(30 * 86_400 + i), :second))
      {:ok, _} = Rollup.run(now: @now)

      assert %{results: 28} = Rollup.prune(now: @now, retention_days: 7, batch_size: 10)
      assert Repo.aggregate(CheckResult, :count) == 2
    end
  end
end
