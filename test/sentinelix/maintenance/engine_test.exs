defmodule Sentinelix.Maintenance.EngineTest do
  @moduledoc """
  Maintenance windows in the monitoring engine and their interaction with
  notifications.
  """
  # Maintenance windows are cached and status events broadcast globally.
  use Sentinelix.DataCase, async: false

  import Sentinelix.MaintenanceFixtures
  import Sentinelix.MonitoringFixtures
  import Sentinelix.NotificationsFixtures

  alias Sentinelix.Checks.Push
  alias Sentinelix.FakeCheck
  alias Sentinelix.{Maintenance, Monitoring, Notifications}
  alias Sentinelix.Monitoring.Supervisor, as: Engine
  alias Sentinelix.Monitoring.Worker
  alias Sentinelix.Notifications.Dispatcher

  @engine __MODULE__.Engine

  setup :reset_maintenance_cache

  setup do
    start_supervised!(FakeCheck)

    start_supervised!(
      {Engine,
       name: @engine,
       manager: false,
       jitter: 0,
       maintenance: Maintenance,
       checks: %{http: FakeCheck, push: Push}}
    )

    task_supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})

    dispatcher =
      start_supervised!(
        {Dispatcher, name: nil, task_supervisor: task_supervisor, delivery: [backoff_ms: 1]}
      )

    Req.Test.allow(Sentinelix.Notifications, self(), dispatcher)
    capture_requests()

    monitor = monitor_fixture(:http, %{name: "Homepage", max_retries: 0})
    url = "https://hooks.example.com/#{System.unique_integer([:positive])}"
    channel = channel_fixture(:webhook, %{config: %{"url" => url}})
    :ok = Notifications.put_monitor_channels(monitor, [channel])
    :ok = Monitoring.subscribe_monitor(monitor)

    %{monitor: monitor, url: url, dispatcher: dispatcher}
  end

  defp start(monitor), do: {:ok, _pid} = Engine.start_worker(monitor, @engine)

  defp check(monitor, result, status) do
    FakeCheck.push(monitor, [result])
    :ok = Worker.check_now(monitor, @engine)
    assert_receive {:check_result, %{status: ^status} = check_result}, 2_000
    check_result
  end

  # Waits until the dispatcher handled all events broadcast so far.
  defp sync(dispatcher), do: :sys.get_state(dispatcher)

  defp end_window(window) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      Maintenance.update_window(window, %{
        starts_at: DateTime.add(now, -2, :hour),
        ends_at: DateTime.add(now, -1, :second)
      })
  end

  test "records maintenance without incidents or notifications, then alerts normally",
       %{monitor: monitor, url: url, dispatcher: dispatcher} do
    FakeCheck.push(monitor, [{:up, %{}}])
    start(monitor)
    assert_receive {:check_result, %{status: :up}}, 2_000
    assert_receive {:status_changed, _, :pending, :up, _}

    window = window_fixture(%{monitor_ids: [monitor.id]})

    result = check(monitor, {:down, %{message: "503"}}, :maintenance)
    assert result.message == "503"
    check(monitor, {:down, %{message: "503"}}, :maintenance)
    refute_received {:status_changed, _, _, _, _}
    refute_received {:incident_opened, _}
    assert %{status: :up} = Worker.info(monitor, @engine)
    assert Monitoring.get_open_incident(monitor) == nil
    sync(dispatcher)
    refute_receive {:notification_request, _}, 100

    # The window ends while the monitor is still down.
    end_window(window)
    check(monitor, {:down, %{message: "503"}}, :down)
    assert_receive {:status_changed, _, :up, :down, _}
    assert_receive {:incident_opened, _}

    assert_receive {:notification_request, %{url: ^url, body: %{"event" => "down"}}}, 1_000
  end

  test "a monitor created after a selector window, with matching labels, is in maintenance",
       %{dispatcher: dispatcher} do
    window_fixture(%{selector: "site=oslo"})

    monitor = monitor_fixture(:http, %{max_retries: 0, labels: %{"site" => "oslo"}})
    other = monitor_fixture(:http, %{max_retries: 0, labels: %{"site" => "bergen"}})
    :ok = Monitoring.subscribe_monitor(monitor)
    :ok = Monitoring.subscribe_monitor(other)

    # The first checks: the engine evaluates the selector on the monitor,
    # without waiting for the cache to see the new monitors.
    FakeCheck.push(monitor, [{:down, %{message: "503"}}])
    FakeCheck.push(other, [{:down, %{message: "503"}}])
    start(monitor)
    start(other)

    assert_receive {:check_result, %{status: :maintenance, monitor_id: id}}, 2_000
    assert id == monitor.id
    assert_receive {:check_result, %{status: :down, monitor_id: other_id}}, 2_000
    assert other_id == other.id
    assert %{status: :pending} = Worker.info(monitor, @engine)
    assert Monitoring.get_open_incident(monitor) == nil
    sync(dispatcher)
  end

  test "an outage notified before the window isn't notified again, a recovery is",
       %{monitor: monitor, url: url} do
    FakeCheck.push(monitor, [{:down, %{message: "503"}}])
    start(monitor)
    assert_receive {:check_result, %{status: :down}}, 2_000
    assert_receive {:notification_request, %{url: ^url, body: %{"event" => "down"}}}, 1_000

    window = window_fixture(%{monitor_ids: [monitor.id]})
    check(monitor, {:up, %{}}, :maintenance)
    check(monitor, {:down, %{}}, :maintenance)
    refute_receive {:notification_request, _}, 100

    end_window(window)
    check(monitor, {:down, %{message: "503"}}, :down)
    refute_receive {:notification_request, _}, 100

    check(monitor, {:up, %{}}, :up)
    assert_receive {:notification_request, %{url: ^url, body: %{"event" => "up"}}}, 1_000
  end

  test "a worker restarted during the window doesn't re-notify an ongoing outage",
       %{monitor: monitor, url: url} do
    FakeCheck.push(monitor, [{:down, %{message: "503"}}])
    start(monitor)
    assert_receive {:check_result, %{status: :down}}, 2_000
    assert_receive {:notification_request, %{url: ^url, body: %{"event" => "down"}}}, 1_000

    window = window_fixture(%{monitor_ids: [monitor.id]})
    check(monitor, {:down, %{}}, :maintenance)

    # e.g. the monitor was edited: the worker restarts from the maintenance result.
    :ok = Engine.stop_worker(monitor, @engine)
    FakeCheck.push(monitor, [{:down, %{}}])
    start(monitor)
    assert_receive {:check_result, %{status: :maintenance}}, 2_000

    end_window(window)
    check(monitor, {:down, %{message: "503"}}, :down)
    refute_receive {:notification_request, _}, 100
    assert [_one] = Monitoring.list_incidents(monitor)
  end

  test "push monitors: pushes and missed deadlines during the window are maintenance" do
    monitor = monitor_fixture(:push, %{interval_seconds: 60, max_retries: 0})
    :ok = Monitoring.subscribe_monitor(monitor)
    {:ok, pid} = Engine.start_worker(monitor, @engine)
    assert {:ok, %{status: :up}} = Worker.push(monitor, {:up, %{}}, @engine)

    window = window_fixture(%{monitor_ids: [monitor.id]})
    assert {:ok, %{status: :maintenance}} = Worker.push(monitor, {:up, %{}}, @engine)
    assert_receive {:check_result, %{status: :up}}
    assert_receive {:check_result, %{status: :maintenance}}

    # The push deadline passes during the window.
    send(pid, :check)
    assert_receive {:check_result, %{status: :maintenance, message: message}}, 2_000
    assert message =~ "No push"
    assert %{status: :up} = Worker.info(monitor, @engine)

    # Still no push after the window: the next deadline check goes down.
    end_window(window)
    send(pid, :check)
    assert_receive {:check_result, %{status: :down}}, 2_000
    assert %{status: :down} = Worker.info(monitor, @engine)
  end
end
