defmodule Sentinelix.Monitoring.HistoryTest do
  use Sentinelix.DataCase, async: true

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

  describe "response_times/2" do
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
  end
end
