defmodule Sentinelix.Monitoring.EventWarningsTest do
  @moduledoc """
  Warnings raised by events in the monitoring worker (the `:warning`
  status).
  """

  use Sentinelix.DataCase, async: false

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Checks.Push
  alias Sentinelix.FakeCheck
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{Events, Incident}
  alias Sentinelix.Monitoring.Supervisor, as: Engine
  alias Sentinelix.Monitoring.Worker

  @engine __MODULE__.Engine

  defmodule AlwaysInMaintenance do
    def active?(_monitor, %DateTime{}), do: true
  end

  setup context do
    start_supervised!(FakeCheck)

    start_supervised!(
      {Engine,
       name: @engine,
       manager: false,
       jitter: 0,
       maintenance: context[:maintenance],
       checks: %{http: FakeCheck, cert: FakeCheck, push: Push}}
    )

    :ok
  end

  defp start(monitor, results \\ []) do
    FakeCheck.push(monitor, results)
    :ok = Monitoring.subscribe_monitor(monitor)
    {:ok, pid} = Engine.start_worker(monitor, @engine)
    pid
  end

  defp event(monitor, params), do: Events.record_event(monitor, params, engine: @engine)

  defp warn(monitor, title, extra \\ %{}),
    do: event(monitor, Map.merge(%{"title" => title, "severity" => "warning"}, extra))

  defp ok(monitor, extra \\ %{}),
    do: event(monitor, Map.merge(%{"title" => "ok", "severity" => "ok"}, extra))

  defp check_now(monitor), do: :ok = Worker.check_now(monitor, @engine)

  defp assert_result(status) do
    assert_receive {:check_result, %{status: ^status} = result}, 2_000
    result
  end

  test "a warning takes an up monitor to warning right away, ok back to up" do
    monitor = monitor_fixture()
    start(monitor)
    assert_result(:up)
    assert_receive {:status_changed, _, :pending, :up, _}

    assert {:ok, _event, :warning} = warn(monitor, "Disk 91% full")
    result = assert_result(:warning)
    assert result.message == "Warning: Disk 91% full"
    assert result.response_time_ms == nil
    assert_receive {:status_changed, _, :up, :warning, ^result}
    assert_receive {:incident_opened, %Incident{to_status: :warning, from_status: :up} = incident}
    assert incident.message == "Warning: Disk 91% full"
    assert %{status: :warning, warned: true} = Worker.info(monitor, @engine)

    # Checks keep it in warning.
    check_now(monitor)
    assert_result(:warning)
    refute_receive {:status_changed, _, _, _, _}, 100

    assert {:ok, _event, :up} = ok(monitor)
    result = assert_result(:up)
    assert result.message == "Warnings cleared"
    assert_receive {:status_changed, _, :warning, :up, ^result}
    assert_receive {:incident_resolved, %{id: id}}
    assert id == incident.id
  end

  test "the monitor stays in warning until every key is cleared" do
    monitor = monitor_fixture()
    start(monitor)
    assert_result(:up)

    {:ok, _, :warning} = warn(monitor, "Disk", %{"key" => "disk"})
    {:ok, _, :warning} = warn(monitor, "Lag", %{"key" => "lag"})
    assert_result(:warning)
    refute_receive {:check_result, _}, 100

    {:ok, _, :warning} = ok(monitor, %{"key" => "disk"})
    refute_receive {:check_result, _}, 100

    {:ok, _, :up} = ok(monitor, %{"key" => "lag"})
    assert_result(:up)
  end

  test "an info event changes nothing" do
    monitor = monitor_fixture()
    start(monitor)
    assert_result(:up)

    assert {:ok, _event, :up} = event(monitor, %{"title" => "Promoted"})
    refute_receive {:check_result, _}, 100
  end

  test "down wins over a warning; recovering returns to warning" do
    monitor = monitor_fixture(:http, %{max_retries: 0})
    start(monitor, [{:up, %{}}, {:down, %{message: "refused"}}, {:up, %{}}])
    assert_result(:up)

    {:ok, _, :warning} = warn(monitor, "Disk")
    assert_result(:warning)
    assert_receive {:incident_opened, %{to_status: :warning} = warning_incident}

    check_now(monitor)
    assert_result(:down)
    assert_receive {:status_changed, _, :warning, :down, _}
    assert_receive {:incident_resolved, %{id: id}}
    assert id == warning_incident.id
    assert_receive {:incident_opened, %{to_status: :down, from_status: :warning}}

    # A warning event while down changes nothing.
    {:ok, _, :down} = warn(monitor, "Disk again")
    refute_receive {:check_result, _}, 100

    check_now(monitor)
    assert_result(:warning)
    assert_receive {:status_changed, _, :down, :warning, _}
    assert_receive {:incident_resolved, %{to_status: :down}}
    assert_receive {:incident_opened, %{to_status: :warning, from_status: :down}}
    assert %Incident{to_status: :warning} = Monitoring.get_open_incident(monitor)
  end

  test "a warning raised while pending applies with the first up check" do
    monitor = monitor_fixture()
    {:ok, _, :pending} = warn(monitor, "Disk")

    start(monitor)
    assert_result(:warning)
    assert_receive {:status_changed, _, :pending, :warning, _}
  end

  test "a warning that expires takes the monitor back up, logging an ok event" do
    monitor = monitor_fixture()
    start(monitor)
    assert_result(:up)

    {:ok, _, :warning} = warn(monitor, "Backup late", %{"ttl" => "1"})
    assert_result(:warning)

    result = assert_result(:up)
    assert result.message == "Warnings cleared"
    assert_receive {:event_recorded, %{severity: :ok, title: "Warning expired: Backup late"}}
    assert Events.active_warnings(monitor) == []
  end

  test "clearing warnings by hand" do
    monitor = monitor_fixture()
    start(monitor)
    assert_result(:up)

    {:ok, _, :warning} = warn(monitor, "Disk")
    assert_result(:warning)

    {:ok, [_]} = Events.clear_warnings(monitor, :all, engine: @engine)
    assert_result(:up)
  end

  test "a restarted worker keeps the warning" do
    monitor = monitor_fixture()
    pid = start(monitor)
    assert_result(:up)
    {:ok, _, :warning} = warn(monitor, "Disk")
    assert_result(:warning)
    assert_receive {:status_changed, _, :pending, :up, _}
    assert_receive {:status_changed, _, :up, :warning, _}
    assert_receive {:incident_opened, _}

    :ok = Engine.stop_worker(monitor, @engine)
    refute Process.alive?(pid)
    {:ok, _pid} = Engine.start_worker(monitor, @engine)

    assert_result(:warning)
    refute_receive {:status_changed, _, _, _, _}, 100
    refute_received {:incident_opened, _}
  end

  test "a restarted worker drops a warning that expired meanwhile" do
    monitor = monitor_fixture()
    check_result_fixture(monitor, %{status: :warning})
    incident_fixture(monitor, %{to_status: :warning})

    {:ok, _, _} =
      Events.record_event(
        monitor,
        %{"title" => "Old", "severity" => "warning", "ttl" => "60"},
        now: DateTime.add(DateTime.utc_now(), -120, :second),
        engine: @engine
      )

    start(monitor)
    assert_result(:up)
    assert_receive {:status_changed, _, :warning, :up, _}
    assert_receive {:incident_resolved, %{to_status: :warning}}
    assert Monitoring.get_open_incident(monitor) == nil
  end

  test "a check's own warning is kept by warning transitions" do
    monitor = monitor_fixture(:cert)
    cert_warning = {:up, %{warning: true, message: "expires soon"}}
    start(monitor, [cert_warning])
    assert_result(:up)
    assert_receive {:warning_raised, _, _}

    {:ok, _, :warning} = warn(monitor, "Disk")
    assert_result(:warning)
    {:ok, _, :up} = ok(monitor)
    assert_result(:up)

    refute_received {:warning_cleared, _, _}
    assert %{warning: true} = Worker.info(monitor, @engine)
  end

  @tag maintenance: AlwaysInMaintenance
  test "maintenance: the status is left alone and reported as maintenance" do
    monitor = monitor_fixture()
    start(monitor)
    assert_result(:maintenance)

    assert {:ok, _, :maintenance} = warn(monitor, "Disk")
    refute_receive {:check_result, _}, 100
  end

  test "push monitors go to warning without a push" do
    monitor = monitor_fixture(:push, %{interval_seconds: 60})
    start(monitor)
    {:ok, _} = Worker.push(monitor, {:up, %{message: "OK"}}, @engine)
    assert_result(:up)

    assert {:ok, _, :warning} = warn(monitor, "Disk")
    assert_result(:warning)

    # Pushes keep it in warning.
    {:ok, %{status: :warning}} = Worker.push(monitor, {:up, %{message: "OK"}}, @engine)
  end

  test "without a running worker the latest result's status is reported" do
    monitor = monitor_fixture()
    check_result_fixture(monitor, %{status: :down})
    assert {:ok, _, :down} = warn(monitor, "Disk")
  end
end
