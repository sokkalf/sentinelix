defmodule Sentinelix.Monitoring.HistoryTest do
  # Not async: creating monitors broadcasts on the global "monitors" topic,
  # which other (async) tests subscribe to.
  use Sentinelix.DataCase, async: false

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring.History

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp result(monitor, status, seconds_ago, attrs \\ %{}) do
    check_result_fixture(
      monitor,
      Map.merge(%{status: status, checked_at: ago(seconds_ago)}, attrs)
    )
  end

  describe "recent_results_by_monitor/2" do
    test "returns the latest results per monitor, oldest first" do
      a = monitor_fixture()
      b = monitor_fixture()
      _empty = monitor_fixture()

      r1 = result(a, :up, 30)
      r2 = result(a, :down, 20)
      r3 = result(a, :up, 10)
      _old = result(a, :up, 40)
      rb = result(b, :up, 5)

      assert %{} = map = History.recent_results_by_monitor(3)
      assert Enum.map(map[a.id], & &1.id) == [r1.id, r2.id, r3.id]
      assert Enum.map(map[b.id], & &1.id) == [rb.id]
      assert map_size(map) == 2
    end

    test "can be restricted to monitor ids" do
      a = monitor_fixture()
      b = monitor_fixture()
      result(a, :up, 1)
      result(b, :up, 1)

      assert Map.keys(History.recent_results_by_monitor(10, [b.id])) == [b.id]
      assert History.recent_results_by_monitor(10, []) == %{}
    end
  end

  describe "uptime" do
    test "counts up vs down, ignoring pending, maintenance and older results" do
      monitor = monitor_fixture()
      other = monitor_fixture()

      result(monitor, :up, 10)
      result(monitor, :up, 20)
      result(monitor, :up, 30)
      result(monitor, :down, 40)
      result(monitor, :pending, 50)
      result(monitor, :maintenance, 60)
      result(monitor, :down, 7200)
      result(other, :down, 10)

      since = ago(3600)
      assert History.uptime(monitor, since) == 75.0
      assert History.uptime_by_monitor(since) == %{monitor.id => 75.0, other.id => 0.0}
      assert History.uptime_by_monitor(since, [monitor.id]) == %{monitor.id => 75.0}
    end

    test "is nil without data" do
      monitor = monitor_fixture()
      assert History.uptime(monitor, ago(3600)) == nil

      result(monitor, :maintenance, 10)
      assert History.uptime(monitor.id, ago(3600)) == nil
    end
  end

  test "average_response_time/2 averages up results only" do
    monitor = monitor_fixture()
    assert History.average_response_time(monitor, ago(3600)) == nil

    result(monitor, :up, 10, %{response_time_ms: 100})
    result(monitor, :up, 20, %{response_time_ms: 200})
    result(monitor, :down, 30, %{response_time_ms: 30_000})

    assert History.average_response_time(monitor, ago(3600)) == 150.0
  end

  describe "response_times/3" do
    test "returns raw points oldest first" do
      monitor = monitor_fixture()
      a = result(monitor, :up, 30, %{response_time_ms: 10})
      b = result(monitor, :down, 20, %{response_time_ms: nil})
      result(monitor, :maintenance, 15, %{response_time_ms: 5})
      result(monitor, :up, 7200, %{response_time_ms: 1})

      assert [
               %{at: at_a, response_time_ms: 10, down: false},
               %{at: at_b, response_time_ms: nil, down: true}
             ] = History.response_times(monitor, ago(3600))

      assert at_a == a.checked_at
      assert at_b == b.checked_at
    end

    test "buckets points" do
      monitor = monitor_fixture()
      base = ~U[2026-01-01 10:00:00.000000Z]

      for {offset, status, ms} <- [{0, :up, 100}, {120, :down, 300}, {3700, :up, 50}] do
        check_result_fixture(monitor, %{
          status: status,
          response_time_ms: ms,
          checked_at: DateTime.add(base, offset, :second)
        })
      end

      assert [
               %{at: ~U[2026-01-01 10:00:00.000000Z], response_time_ms: 200, down: true},
               %{at: ~U[2026-01-01 11:00:00.000000Z], response_time_ms: 50, down: false}
             ] = History.response_times(monitor, base, bucket_seconds: 3600)
    end
  end
end
