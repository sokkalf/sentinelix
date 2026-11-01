defmodule Sentinelix.Notifications.DispatcherTest do
  # Status events are broadcast on a global topic.
  use Sentinelix.DataCase, async: false

  import ExUnit.CaptureLog
  import Sentinelix.MonitoringFixtures
  import Sentinelix.NotificationsFixtures

  alias Sentinelix.FakeCheck
  alias Sentinelix.{Monitoring, Notifications}
  alias Sentinelix.Monitoring.Supervisor, as: Engine
  alias Sentinelix.Monitoring.Worker
  alias Sentinelix.Notifications.Dispatcher

  @engine __MODULE__.Engine

  setup do
    task_supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})

    dispatcher =
      start_supervised!(
        {Dispatcher,
         name: nil, task_supervisor: task_supervisor, delivery: [max_attempts: 3, backoff_ms: 1]}
      )

    # Let the dispatcher (and its send tasks, via $callers) use our stubs.
    Req.Test.allow(Sentinelix.Notifications, self(), dispatcher)
    capture_requests()
    Process.put(:dispatcher, dispatcher)

    monitor = monitor_fixture(:http, %{name: "Homepage"})
    %{dispatcher: dispatcher, monitor: monitor}
  end

  defp status_changed(monitor, old, new, attrs \\ %{}) do
    result = check_result_fixture(monitor, Enum.into(attrs, %{status: new, message: "msg"}))
    broadcast(monitor, {:status_changed, monitor, old, new, result})
  end

  defp warning(monitor, event) do
    result = check_result_fixture(monitor, %{status: :up, message: "Certificate expires soon"})
    broadcast(monitor, {event, monitor, result})
  end

  defp broadcast(monitor, event) do
    Monitoring.broadcast_status_event(monitor, event)
    # Wait until the dispatcher has handled the event.
    :sys.get_state(dispatcher())
  end

  defp dispatcher, do: Process.get(:dispatcher)

  defp assert_notified(url, title) do
    assert_receive {:notification_request, %{url: ^url, body: %{"title" => ^title}}}, 1_000
  end

  defp refute_notified, do: refute_receive({:notification_request, _}, 100)

  # Waits until all sends started so far (including their retries) are done.
  defp await_deliveries do
    for pid <- Task.Supervisor.children(__MODULE__.Tasks) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end
  end

  defp webhook(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    url = "https://hooks.example.com/#{n}"
    channel = channel_fixture(:webhook, Map.put(attrs, :config, %{"url" => url}))
    {channel, url}
  end

  test "a status change is sent to the monitor's enabled channels only", %{monitor: monitor} do
    {a, url_a} = webhook()
    {b, url_b} = webhook()
    {disabled, _} = webhook(%{enabled: false})
    {_unrelated, _} = webhook()
    :ok = Notifications.put_monitor_channels(monitor, [a, b, disabled])

    status_changed(monitor, :up, :down, message: "503 Service Unavailable")

    assert_receive {:notification_request, %{url: ^url_a, body: body}}, 1_000
    assert body["event"] == "down"
    assert body["message"] == "503 Service Unavailable"
    assert body["monitor"]["name"] == "Homepage"
    assert body["monitor"]["url"] =~ "/monitors/#{monitor.id}"
    assert_notified(url_b, "[DOWN] Homepage is down")
    refute_notified()
  end

  test "notifies down and recovery, not pending transitions", %{monitor: monitor} do
    {channel, url} = webhook()
    :ok = Notifications.put_monitor_channels(monitor, [channel])

    status_changed(monitor, :pending, :up)
    status_changed(monitor, :up, :pending)
    refute_notified()

    status_changed(monitor, :pending, :down)
    assert_notified(url, "[DOWN] Homepage is down")

    status_changed(monitor, :down, :up)
    assert_notified(url, "[UP] Homepage is back up")

    status_changed(monitor, :up, :pending)
    status_changed(monitor, :pending, :up)
    refute_notified()
  end

  test "does not repeat a down notification", %{monitor: monitor} do
    {channel, url} = webhook()
    :ok = Notifications.put_monitor_channels(monitor, [channel])

    status_changed(monitor, :up, :down)
    assert_notified(url, "[DOWN] Homepage is down")

    # e.g. the worker restarted after a maintenance result (pending -> down)
    status_changed(monitor, :pending, :down)
    refute_notified()

    # recovering via pending after such a restart is still a recovery
    status_changed(monitor, :pending, :up)
    assert_notified(url, "[UP] Homepage is back up")
  end

  test "notifies a recovery of a monitor that was down before notifications were set up",
       %{monitor: monitor} do
    {channel, url} = webhook()
    :ok = Notifications.put_monitor_channels(monitor, [channel])

    status_changed(monitor, :down, :up)
    assert_notified(url, "[UP] Homepage is back up")
  end

  test "certificate warnings are notified once, also across worker restarts",
       %{monitor: monitor} do
    {channel, url} = webhook()
    :ok = Notifications.put_monitor_channels(monitor, [channel])

    warning(monitor, :warning_raised)
    assert_notified(url, "[WARNING] Homepage has a warning")

    # a restarted worker raises the active warning again
    warning(monitor, :warning_raised)
    refute_notified()

    warning(monitor, :warning_cleared)
    assert_notified(url, "[OK] Homepage warning cleared")

    warning(monitor, :warning_cleared)
    refute_notified()
  end

  test "the warning status raised by events is notified as a warning", %{monitor: monitor} do
    {channel, url} = webhook()
    :ok = Notifications.put_monitor_channels(monitor, [channel])

    status_changed(monitor, :pending, :up)
    status_changed(monitor, :up, :warning, message: "Warning: Disk 91% full")
    assert_receive {:notification_request, %{url: ^url, body: body}}, 1_000
    assert body["event"] == "warning"
    assert body["message"] == "Warning: Disk 91% full"

    # e.g. a restarted worker
    status_changed(monitor, :pending, :warning)
    refute_notified()

    status_changed(monitor, :warning, :up, message: "Warnings cleared")
    assert_notified(url, "[OK] Homepage warning cleared")
    status_changed(monitor, :up, :pending)
    status_changed(monitor, :pending, :up)
    refute_notified()
  end

  test "down and back to the warning status: down, recovery and the warning again",
       %{monitor: monitor} do
    {channel, url} = webhook()
    :ok = Notifications.put_monitor_channels(monitor, [channel])

    status_changed(monitor, :up, :warning)
    assert_notified(url, "[WARNING] Homepage has a warning")

    status_changed(monitor, :warning, :down)
    assert_notified(url, "[DOWN] Homepage is down")

    status_changed(monitor, :down, :warning)
    assert_notified(url, "[UP] Homepage is back up")
    assert_notified(url, "[WARNING] Homepage has a warning")
    refute_notified()
  end

  test "a recovery resets the warning", %{monitor: monitor} do
    {channel, url} = webhook()
    :ok = Notifications.put_monitor_channels(monitor, [channel])

    warning(monitor, :warning_raised)
    assert_notified(url, "[WARNING] Homepage has a warning")

    status_changed(monitor, :up, :down)
    assert_notified(url, "[DOWN] Homepage is down")
    status_changed(monitor, :down, :up)
    assert_notified(url, "[UP] Homepage is back up")

    warning(monitor, :warning_raised)
    assert_notified(url, "[WARNING] Homepage has a warning")
  end

  test "down, recovery and warnings go to the channels routed by selector too",
       %{monitor: monitor} do
    {:ok, monitor} = Monitoring.update_monitor(monitor, %{labels: %{"env" => "prod"}})
    {attached, url_attached} = webhook()
    {_routed, url_routed} = webhook(%{selector: "env=prod"})
    {_disabled, _} = webhook(%{selector: "env=prod", enabled: false})
    {_staging, _} = webhook(%{selector: "env=staging"})
    {_no_selector, _} = webhook()
    :ok = Notifications.put_monitor_channels(monitor, [attached])

    status_changed(monitor, :up, :down)
    assert_notified(url_attached, "[DOWN] Homepage is down")
    assert_notified(url_routed, "[DOWN] Homepage is down")
    refute_notified()

    status_changed(monitor, :down, :up)
    assert_notified(url_attached, "[UP] Homepage is back up")
    assert_notified(url_routed, "[UP] Homepage is back up")
    refute_notified()

    warning(monitor, :warning_raised)
    assert_notified(url_attached, "[WARNING] Homepage has a warning")
    assert_notified(url_routed, "[WARNING] Homepage has a warning")
    refute_notified()
  end

  test "routing uses the labels at event time, not the event's monitor",
       %{monitor: monitor} do
    {_channel, url} = webhook(%{selector: "env=prod"})

    status_changed(monitor, :up, :down)
    refute_notified()

    {:ok, _} = Monitoring.update_monitor(monitor, %{labels: %{"env" => "prod"}})

    # `monitor` (the event's copy) has no labels: they are read again.
    status_changed(monitor, :down, :up)
    assert_notified(url, "[UP] Homepage is back up")
  end

  test "failing sends are retried", %{monitor: monitor} do
    {channel, url} = webhook()
    :ok = Notifications.put_monitor_channels(monitor, [channel])

    counter = :counters.new(1, [])
    test_pid = self()

    Req.Test.stub(Sentinelix.Notifications, fn conn ->
      :counters.add(counter, 1, 1)
      send(test_pid, {:attempt, Plug.Conn.request_url(conn)})

      if :counters.get(counter, 1) < 3,
        do: Plug.Conn.send_resp(conn, 503, "unavailable"),
        else: Req.Test.json(conn, %{})
    end)

    log =
      capture_log(fn ->
        status_changed(monitor, :up, :down)
        for _ <- 1..3, do: assert_receive({:attempt, ^url}, 1_000)
        refute_receive {:attempt, _}, 100
      end)

    assert log =~ "HTTP 503: unavailable"
    refute log =~ "giving up"
  end

  test "broken providers and bad events don't crash the dispatcher",
       %{monitor: monitor, dispatcher: dispatcher} do
    {channel, _url} = webhook()
    {other, other_url} = webhook()
    :ok = Notifications.put_monitor_channels(monitor, [channel, other])

    test_pid = self()

    Req.Test.stub(Sentinelix.Notifications, fn conn ->
      if Plug.Conn.request_url(conn) == other_url do
        send(test_pid, :other_sent)
        Req.Test.json(conn, %{})
      else
        raise "provider exploded"
      end
    end)

    log =
      capture_log(fn ->
        status_changed(monitor, :up, :down)
        assert_receive :other_sent, 1_000
        # the failing channel gives up after its attempts
        await_deliveries()

        # events for monitors that no longer exist
        {:ok, deleted} = Monitoring.delete_monitor(monitor_fixture())
        broadcast(deleted, {:status_changed, deleted, :up, :down, nil})

        send(dispatcher, :unexpected)
        :sys.get_state(dispatcher)
      end)

    assert log =~ "provider exploded"
    assert log =~ "failed to handle :status_changed"
    assert Process.alive?(dispatcher)
  end

  describe "with the monitoring engine" do
    setup do
      start_supervised!(FakeCheck)

      start_supervised!(
        {Engine, name: @engine, manager: false, jitter: 0, checks: %{http: FakeCheck}}
      )

      :ok
    end

    test "notifies when a monitor goes down and recovers, but not again after a restart",
         %{monitor: monitor} do
      {channel, url} = webhook()
      :ok = Notifications.put_monitor_channels(monitor, [channel])
      :ok = Monitoring.subscribe_monitor(monitor)

      FakeCheck.push(monitor, [{:down, %{message: "connection refused"}}])
      {:ok, _pid} = Engine.start_worker(monitor, @engine)
      assert_receive {:status_changed, _, :pending, :down, _}, 2_000
      assert_receive {:notification_request, %{url: ^url, body: body}}, 1_000
      assert %{"event" => "down", "message" => "connection refused"} = body

      # Restarting the worker (e.g. after an edit or reboot) while still down.
      :ok = Engine.stop_worker(monitor, @engine)
      FakeCheck.push(monitor, [{:down, %{message: "connection refused"}}])
      {:ok, _pid} = Engine.start_worker(monitor, @engine)
      assert_receive {:check_result, %{status: :down}}, 2_000
      :sys.get_state(dispatcher())
      refute_notified()

      FakeCheck.push(monitor, [{:up, %{message: "200 OK"}}])
      :ok = Worker.check_now(monitor, @engine)
      assert_receive {:status_changed, _, :down, :up, _}, 2_000
      assert_notified(url, "[UP] Homepage is back up")
    end
  end
end
