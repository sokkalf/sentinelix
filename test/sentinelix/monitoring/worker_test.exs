defmodule Sentinelix.Monitoring.WorkerTest do
  use Sentinelix.DataCase, async: false

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.FakeCheck
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Supervisor, as: Engine
  alias Sentinelix.Monitoring.Worker

  @engine __MODULE__.Engine

  defmodule AlwaysInMaintenance do
    def active?(_monitor, %DateTime{}), do: true
  end

  setup do
    start_supervised!(FakeCheck)

    start_supervised!(
      {Engine,
       name: @engine, manager: false, jitter: 0, checks: %{http: FakeCheck, cert: FakeCheck}}
    )

    :ok
  end

  defp start(monitor, results \\ []) do
    FakeCheck.push(monitor, results)
    :ok = Monitoring.subscribe_monitor(monitor)
    {:ok, pid} = Engine.start_worker(monitor, @engine)
    pid
  end

  defp check_now(monitor), do: :ok = Worker.check_now(monitor, @engine)

  defp assert_result(status) do
    assert_receive {:check_result, %{status: ^status} = result}, 2_000
    result
  end

  defp results(monitor),
    do: monitor |> Monitoring.latest_results() |> Enum.map(& &1.status) |> Enum.reverse()

  test "runs the first check immediately and records it" do
    monitor = monitor_fixture()
    start(monitor, [{:up, %{response_time_ms: 42, status_code: 200, message: "200 OK"}}])

    result = assert_result(:up)
    assert %{response_time_ms: 42, status_code: 200, message: "200 OK"} = result

    assert_receive {:status_changed, %{id: id}, :pending, :up, ^result}
    assert id == monitor.id

    info = Worker.info(monitor, @engine)
    assert %{status: :up, retries: 0, checking: false} = info
    # Next check after interval_seconds.
    assert_in_delta DateTime.diff(info.next_check_at, DateTime.utc_now(), :second),
                    monitor.interval_seconds,
                    1
  end

  test "broadcasts status changes on the status_changes topic" do
    :ok = Monitoring.subscribe_status_changes()
    monitor = monitor_fixture()
    FakeCheck.push(monitor, [{:down, %{message: "nope"}}])
    {:ok, _pid} = Engine.start_worker(monitor, @engine)

    assert_receive {:status_changed, %{id: id}, :pending, :down,
                    %{status: :down, message: "nope"}},
                   2_000

    assert id == monitor.id
  end

  test "goes down right away without retries, opening an incident" do
    monitor = monitor_fixture(:http, %{max_retries: 0})
    start(monitor, [{:up, %{}}, {:down, %{message: "boom"}}, {:down, %{message: "still"}}])

    assert_result(:up)
    assert_receive {:status_changed, _, :pending, :up, _}

    check_now(monitor)
    result = assert_result(:down)
    assert_receive {:status_changed, _, :up, :down, ^result}
    assert_receive {:incident_opened, incident}
    assert %{from_status: :up, to_status: :down, message: "boom"} = incident

    # Staying down is not a transition and doesn't open another incident.
    check_now(monitor)
    assert_result(:down)
    refute_receive {:status_changed, _, _, _, _}, 100
    refute_received {:incident_opened, _}
    assert Monitoring.get_open_incident(monitor).id == incident.id
  end

  test "retries max_retries times as pending before going down" do
    monitor = monitor_fixture(:http, %{max_retries: 2, retry_interval_seconds: 20})
    start(monitor, [{:up, %{}}, {:down, %{}}, {:down, %{}}, {:down, %{}}])

    assert_result(:up)

    check_now(monitor)
    assert_result(:pending)
    assert_receive {:status_changed, _, :up, :pending, _}
    info = Worker.info(monitor, @engine)
    assert info.retries == 1
    # Retries use the retry interval.
    assert_in_delta DateTime.diff(info.next_check_at, DateTime.utc_now(), :second), 20, 1

    check_now(monitor)
    assert_result(:pending)
    assert Worker.info(monitor, @engine).retries == 2
    refute_received {:incident_opened, _}

    check_now(monitor)
    assert_result(:down)
    assert_receive {:status_changed, _, :pending, :down, _}
    assert_receive {:incident_opened, %{from_status: :pending, to_status: :down}}
    assert results(monitor) == [:up, :pending, :pending, :down]
  end

  test "recovering from pending resets the retries without an incident" do
    monitor = monitor_fixture(:http, %{max_retries: 1})
    start(monitor, [{:up, %{}}, {:down, %{}}, {:up, %{}}, {:down, %{}}])

    assert_result(:up)
    check_now(monitor)
    assert_result(:pending)
    check_now(monitor)
    assert_result(:up)
    assert_receive {:status_changed, _, :pending, :up, _}

    # A full retry budget again.
    check_now(monitor)
    assert_result(:pending)
    refute_received {:incident_opened, _}
  end

  test "coming back up resolves the incident" do
    monitor = monitor_fixture()
    start(monitor, [{:down, %{message: "down"}}, {:up, %{message: "back"}}])

    assert_result(:down)
    assert_receive {:status_changed, _, :pending, :down, _}
    assert_receive {:incident_opened, incident}

    check_now(monitor)
    result = assert_result(:up)
    assert_receive {:status_changed, _, :down, :up, ^result}
    assert_receive {:incident_resolved, resolved}
    assert resolved.id == incident.id
    assert resolved.resolved_at == result.checked_at
    assert Monitoring.get_open_incident(monitor) == nil
  end

  test "restores the status and open incident from the database" do
    monitor = monitor_fixture()
    check_result_fixture(monitor, %{status: :down})
    incident = incident_fixture(monitor)

    start(monitor, [{:down, %{}}, {:up, %{}}])

    # Still down: no transition, no new incident.
    assert_result(:down)
    refute_receive {:status_changed, _, _, _, _}, 100
    refute_received {:incident_opened, _}

    check_now(monitor)
    assert_result(:up)
    assert_receive {:status_changed, _, :down, :up, _}
    assert_receive {:incident_resolved, %{id: id}}
    assert id == incident.id
  end

  test "a hanging check times out as down" do
    monitor = monitor_fixture(:http, %{timeout_ms: 100})
    pid = start(monitor, [:hang])

    result = assert_result(:down)
    assert result.message == "Timed out after 100 ms"
    assert Process.alive?(pid)
  end

  test "the worker stays responsive while a check runs" do
    monitor = monitor_fixture(:http, %{timeout_ms: 1_000})
    start(monitor, [:hang])

    assert %{checking: true, next_check_at: nil} = Worker.info(monitor, @engine)
    # A check is already running, so this one is skipped.
    check_now(monitor)
    assert_result(:down)
    refute_receive {:check_result, _}, 100
  end

  @tag :capture_log
  test "a crashing check or invalid result is down" do
    monitor = monitor_fixture()
    start(monitor, [:raise, :nonsense])

    assert assert_result(:down).message =~ "Check crashed: ** (RuntimeError) boom"

    check_now(monitor)
    assert assert_result(:down).message =~ "invalid result: :nonsense"
  end

  test "warnings are broadcast when raised and cleared" do
    monitor = monitor_fixture(:cert)
    warning = {:up, %{warning: true, message: "Warning: expires soon"}}
    start(monitor, [warning, warning, {:up, %{message: "renewed"}}])

    result = assert_result(:up)
    assert result.message == "Warning: expires soon"
    assert_receive {:warning_raised, %{id: id}, ^result}
    assert id == monitor.id

    check_now(monitor)
    assert_result(:up)
    refute_receive {:warning_raised, _, _}, 100

    check_now(monitor)
    result = assert_result(:up)
    assert_receive {:warning_cleared, _, ^result}
  end

  test "fills in the response time when the check doesn't report one" do
    monitor = monitor_fixture()
    start(monitor, [{:up, %{}}])
    assert is_integer(assert_result(:up).response_time_ms)
  end

  test "emits telemetry events" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:sentinelix, :check, :stop]])
    on_exit(fn -> :telemetry.detach(ref) end)

    monitor = monitor_fixture(:http, %{timeout_ms: 100})
    start(monitor, [{:up, %{response_time_ms: 7, meta: %{days_remaining: 3}}}, :hang])

    assert_receive {[:sentinelix, :check, :stop], ^ref, measurements, metadata}, 2_000
    assert is_integer(measurements.duration)
    assert measurements.response_time_ms == 7

    assert metadata == %{
             monitor_id: monitor.id,
             monitor_type: :http,
             result: :up,
             status: :up,
             error: nil,
             meta: %{days_remaining: 3}
           }

    check_now(monitor)

    assert_receive {[:sentinelix, :check, :stop], ^ref, _, %{result: :down, error: :timeout}},
                   2_000
  end

  test "records maintenance without transitions or incidents" do
    engine = __MODULE__.MaintenanceEngine

    start_supervised!(
      {Engine,
       name: engine,
       manager: false,
       jitter: 0,
       maintenance: AlwaysInMaintenance,
       checks: %{http: FakeCheck}},
      id: engine
    )

    monitor = monitor_fixture()
    FakeCheck.push(monitor, [{:down, %{message: "down"}}])
    Monitoring.subscribe_monitor(monitor)
    {:ok, _pid} = Engine.start_worker(monitor, engine)

    result = assert_result(:maintenance)
    assert result.message == "down"
    refute_receive {:status_changed, _, _, _, _}, 100
    refute_received {:incident_opened, _}
    assert %{status: :pending} = Worker.info(monitor, engine)
  end

  test "stops when its monitor was deleted" do
    monitor = monitor_fixture()
    pid = start(monitor)
    assert_result(:up)

    ref = Process.monitor(pid)
    {:ok, _} = Monitoring.delete_monitor(monitor)
    check_now(monitor)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "check_now without a running worker" do
    assert Worker.check_now(monitor_fixture(), @engine) == {:error, :not_running}
    assert Worker.info(monitor_fixture(), @engine) == nil
  end
end
