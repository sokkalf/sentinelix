defmodule Sentinelix.Monitoring.ManagerTest do
  use Sentinelix.DataCase, async: false

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.FakeCheck
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Supervisor, as: Engine

  @engine __MODULE__.Engine

  setup do
    start_supervised!(FakeCheck)
    :ok
  end

  defp start_engine do
    start_supervised!(
      {Engine, name: @engine, jitter: 0, checks: %{http: FakeCheck, cert: FakeCheck}}
    )
  end

  # The manager reacts to PubSub events asynchronously.
  defp eventually(fun, attempts \\ 50) do
    if fun.() do
      true
    else
      if attempts == 0, do: flunk("condition not met in time")
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp running?(monitor), do: Engine.whereis(monitor, @engine) != nil

  test "starts workers for the enabled monitors with a check on boot" do
    http = monitor_fixture(:http)
    cert = monitor_fixture(:cert)
    disabled = monitor_fixture(:http, %{enabled: false})
    # No check registered for tcp in this engine.
    tcp = monitor_fixture(:tcp)

    Monitoring.subscribe_monitor(http)
    start_engine()

    eventually(fn -> Engine.running_monitor_ids(@engine) == Enum.sort([http.id, cert.id]) end)
    refute running?(disabled)
    refute running?(tcp)

    # ... and they start checking right away.
    assert_receive {:check_result, %{status: :up}}, 2_000
  end

  test "follows monitor changes" do
    start_engine()

    monitor = monitor_fixture(:http)
    eventually(fn -> running?(monitor) end)
    pid = Engine.whereis(monitor, @engine)

    # An update restarts the worker with the new configuration.
    {:ok, monitor} = Monitoring.update_monitor(monitor, %{name: "Renamed"})
    eventually(fn -> running?(monitor) and Engine.whereis(monitor, @engine) != pid end)

    # Disabling stops it, enabling starts it again.
    {:ok, monitor} = Monitoring.toggle_monitor(monitor)
    eventually(fn -> not running?(monitor) end)
    {:ok, monitor} = Monitoring.toggle_monitor(monitor)
    eventually(fn -> running?(monitor) end)

    {:ok, _} = Monitoring.delete_monitor(monitor)
    eventually(fn -> not running?(monitor) end)

    # Created disabled: not started.
    disabled = monitor_fixture(:http, %{enabled: false})
    other = monitor_fixture(:http)
    eventually(fn -> running?(other) end)
    refute running?(disabled)
  end

  test "workers that crash are restarted" do
    monitor = monitor_fixture(:http)
    start_engine()
    eventually(fn -> running?(monitor) end)

    pid = Engine.whereis(monitor, @engine)
    Process.exit(pid, :kill)
    eventually(fn -> running?(monitor) and Engine.whereis(monitor, @engine) != pid end)
  end

  test "check_now via the context" do
    assert Monitoring.check_now(monitor_fixture()) == {:error, :not_running}
    assert Monitoring.worker_info(monitor_fixture()) == nil
  end
end
