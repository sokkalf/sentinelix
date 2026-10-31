defmodule Sentinelix.StatsTest do
  # Not async: the rollup watermark is a single row shared by all tests.
  use Sentinelix.DataCase, async: false

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Stats
  alias Sentinelix.Stats.Rollup

  @now ~U[2026-10-30 12:30:00.000000Z]

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  defp result(monitor, status, checked_at, response_time_ms \\ nil) do
    check_result_fixture(monitor, %{
      status: status,
      checked_at: checked_at,
      response_time_ms: response_time_ms
    })
  end

  setup do
    %{monitor: monitor_fixture()}
  end

  describe "summary/3 and uptime/3" do
    test "no data", %{monitor: monitor} do
      assert Stats.uptime(monitor, {24, :hour}, now: @now) == nil

      assert %{
               uptime: nil,
               up: 0,
               down: 0,
               pending: 0,
               maintenance: 0,
               total: 0,
               avg_ms: nil,
               min_ms: nil,
               max_ms: nil,
               p95_ms: nil
             } = Stats.summary(monitor, {24, :hour}, now: @now)
    end

    test "only maintenance results have no uptime", %{monitor: monitor} do
      for i <- 1..3, do: result(monitor, :maintenance, ago(i * 60), 10)

      summary = Stats.summary(monitor.id, {24, :hour}, now: @now)
      assert summary.uptime == nil
      assert summary.maintenance == 3
      assert summary.total == 3
      # Response stats only cover :up results.
      assert summary.avg_ms == nil
    end

    test "mixed results exclude maintenance and pending", %{monitor: monitor} do
      result(monitor, :up, ago(60), 100)
      result(monitor, :up, ago(120), 200)
      result(monitor, :up, ago(180), 300)
      result(monitor, :down, ago(240), 30_000)
      result(monitor, :pending, ago(300), 30_000)
      result(monitor, :maintenance, ago(360))
      result(monitor, :maintenance, ago(420))

      summary = Stats.summary(monitor, {24, :hour}, now: @now)

      assert summary.uptime == 75.0
      assert %{up: 3, down: 1, pending: 1, maintenance: 2, total: 7} = summary
      assert summary.avg_ms == 200.0
      assert summary.min_ms == 100
      assert summary.max_ms == 300
      assert_in_delta summary.p95_ms, 290.0, 0.001
      assert Stats.uptime(monitor, {24, :hour}, now: @now) == 75.0
    end

    test "unreachable results count as downtime", %{monitor: monitor} do
      result(monitor, :up, ago(60), 100)
      result(monitor, :unreachable, ago(120), 30_000)
      result(monitor, :down, ago(180), 30_000)
      result(monitor, :up, ago(240), 100)

      summary = Stats.summary(monitor, {24, :hour}, now: @now)

      assert summary.uptime == 50.0
      assert %{up: 2, down: 1, unreachable: 1, total: 4} = summary
      assert summary.max_ms == 100

      assert Stats.uptime_percent(%{unreachable: 1}) == 0.0
      assert Stats.uptime_percent(%{up: 0, down: 0, pending: 3}) == nil
    end

    test "only counts results inside the window", %{monitor: monitor} do
      result(monitor, :down, ago(25 * 3600))
      result(monitor, :up, ago(3600))
      # `to` is exclusive.
      result(monitor, :down, @now)

      assert Stats.uptime(monitor, {24, :hour}, now: @now) == 100.0
      assert Stats.uptime(monitor, {2, :day}, now: @now) == 50.0

      assert Stats.uptime(monitor, {ago(26 * 3600), ago(24 * 3600)}) == 0.0
      assert Stats.uptime(monitor, {ago(3600), DateTime.add(@now, 1, :second)}) == 50.0
    end

    test "only counts the monitor's own results", %{monitor: monitor} do
      other = monitor_fixture()
      result(monitor, :up, ago(60))
      result(other, :down, ago(60))

      assert Stats.uptime(monitor, {1, :hour}, now: @now) == 100.0
    end
  end

  describe "uptimes/3 and summaries/3" do
    test "returns stats for many monitors at once", %{monitor: monitor} do
      other = monitor_fixture()
      empty = monitor_fixture()

      result(monitor, :up, ago(60))
      result(other, :up, ago(60))
      result(other, :down, ago(120))

      assert Stats.uptimes([monitor, other.id, empty], {24, :hour}, now: @now) == %{
               monitor.id => 100.0,
               other.id => 50.0,
               empty.id => nil
             }

      summaries = Stats.summaries([monitor, other], {24, :hour}, now: @now)
      assert summaries[other.id].down == 1
      assert summaries[monitor.id].up == 1
    end

    test "with no monitors" do
      assert Stats.uptimes([], {24, :hour}) == %{}
    end
  end

  describe "with rollups" do
    # Results every 10 minutes over the last 3 days: up with 100..150 ms,
    # except down between 30 and 32 hours ago, unreachable between 40 and 41
    # hours ago, and maintenance for the first hour of each day.
    setup %{monitor: monitor} do
      for i <- 0..(3 * 24 * 6 - 1) do
        at = ago(i * 600 + 7)
        hours_ago = i * 600 / 3600

        cond do
          at.hour == 0 -> result(monitor, :maintenance, at)
          hours_ago >= 30 and hours_ago < 32 -> result(monitor, :down, at, 5_000)
          hours_ago >= 40 and hours_ago < 41 -> result(monitor, :unreachable, at, 5_000)
          true -> result(monitor, :up, at, 100 + rem(i, 6) * 10)
        end
      end

      :ok
    end

    test "give the same results as raw data", %{monitor: monitor} do
      windows = [{1, :hour}, {24, :hour}, {7, :day}, {ago(40 * 3600 + 1234), ago(1800)}]

      before =
        Map.new(windows, fn window ->
          {window,
           {Stats.summary(monitor, window, now: @now), Stats.hourly(monitor, window, now: @now)}}
        end)

      daily = Stats.daily_uptime(monitor, 5, now: @now)

      assert {:ok, count} = Rollup.run(now: @now)
      assert count > 0

      for window <- windows do
        {summary, hourly} = before[window]
        assert_same_summary(Stats.summary(monitor, window, now: @now), summary)

        rolled_up = Stats.hourly(monitor, window, now: @now)
        assert Enum.map(rolled_up, & &1.hour) == Enum.map(hourly, & &1.hour)
        Enum.zip_with(rolled_up, hourly, &assert_same_summary/2)
      end

      assert Stats.daily_uptime(monitor, 5, now: @now) == daily
    end

    test "keep the statistics after raw results are pruned", %{monitor: monitor} do
      summary = Stats.summary(monitor, {7, :day}, now: @now)
      daily = Stats.daily_uptime(monitor, 5, now: @now)

      {:ok, _} = Rollup.run(now: @now)
      assert %{results: pruned} = Rollup.prune(now: @now, retention_days: 1)
      assert pruned > 0

      after_prune = Stats.summary(monitor, {7, :day}, now: @now)
      assert_same_summary(Map.delete(after_prune, :p95_ms), Map.delete(summary, :p95_ms))
      assert Stats.daily_uptime(monitor, 5, now: @now) == daily
    end

    test "daily_uptime/3 per day", %{monitor: monitor} do
      {:ok, _} = Rollup.run(now: @now)

      days = Stats.daily_uptime(monitor, 5, now: @now)

      assert Enum.map(days, & &1.date) ==
               [~D[2026-10-26], ~D[2026-10-27], ~D[2026-10-28], ~D[2026-10-29], ~D[2026-10-30]]

      assert [%{uptime: nil, up: 0}, %{uptime: 100.0} = first | _] = days
      # The first day only has results from 12:30 on.
      assert first.maintenance == 0
      # 30..32 hours ago is 2026-10-29 04:30..06:30: 12 down results.
      assert %{down: 12, maintenance: 6} = Enum.at(days, 3)
      assert Enum.at(days, 3).uptime == 100 * (24 * 6 - 6 - 12) / (24 * 6 - 6)
      assert %{down: 0, maintenance: 6, uptime: 100.0} = Enum.at(days, 4)

      other = monitor_fixture()
      other_id = other.id
      assert %{^other_id => other_days} = Stats.daily_uptime([other], 5, now: @now)
      assert length(other_days) == 5
      assert Enum.all?(other_days, &is_nil(&1.uptime))
    end
  end

  defp assert_same_summary(actual, expected) do
    for {key, value} <- expected do
      if is_float(value),
        do: assert_in_delta(actual[key], value, 0.0001, "#{key}"),
        else: assert(actual[key] == value, "#{key}: #{inspect(actual[key])} != #{inspect(value)}")
    end
  end
end
