defmodule Sentinelix.Stats.SchedulerTest do
  use Sentinelix.DataCase, async: false

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring.CheckResult
  alias Sentinelix.Stats.{HourlyStat, Rollup, Scheduler}

  defp eventually(fun, attempts \\ 100) do
    if fun.() do
      true
    else
      if attempts == 0, do: flunk("condition not met in time")
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  test "is not started when disabled" do
    assert Scheduler.start_link(enabled: false) == :ignore
  end

  test "rolls up and prunes periodically" do
    monitor = monitor_fixture()
    old = DateTime.add(DateTime.utc_now(), -200, :day)
    check_result_fixture(monitor, %{status: :up, checked_at: old})
    check_result_fixture(monitor, %{status: :up, checked_at: DateTime.add(old, 1, :day)})

    start_supervised!(
      {Scheduler,
       name: __MODULE__.Scheduler,
       initial_delay: 0,
       rollup_interval: :timer.minutes(1),
       prune_interval: :timer.minutes(1)}
    )

    # Rolls up before pruning, so the statistics survive.
    eventually(fn -> Repo.aggregate(CheckResult, :count) == 0 end)
    assert Rollup.watermark() != nil
    assert Repo.aggregate(HourlyStat, :count) == 2
  end
end
