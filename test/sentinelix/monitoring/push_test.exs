defmodule Sentinelix.Monitoring.PushTest do
  @moduledoc """
  Passive (push) monitors in the worker.
  """
  use Sentinelix.DataCase, async: false

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Checks.Push
  alias Sentinelix.FakeCheck
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Supervisor, as: Engine
  alias Sentinelix.Monitoring.Worker

  @engine __MODULE__.Engine

  defmodule AlwaysInMaintenance do
    def active?(_monitor, %DateTime{}), do: true
  end

  defp start_engine(opts \\ []) do
    start_supervised!(
      {Engine,
       [name: @engine, manager: false, jitter: 0, checks: %{push: Push, http: FakeCheck}] ++
         opts}
    )
  end

  defp start(monitor) do
    :ok = Monitoring.subscribe_monitor(monitor)
    {:ok, pid} = Engine.start_worker(monitor, @engine)
    pid
  end

  defp push(monitor, result), do: Worker.push(monitor, result, @engine)

  # Simulates the deadline timer firing.
  defp miss_deadline(pid), do: send(pid, :check)

  defp seconds_until(datetime), do: DateTime.diff(datetime, DateTime.utc_now(), :second)

  test "waits for the first push instead of checking right away" do
    start_engine()
    monitor = monitor_fixture(:push, %{interval_seconds: 60, settings: %{push_grace_seconds: 15}})
    start(monitor)

    refute_receive {:check_result, _}, 100
    info = Worker.info(monitor, @engine)
    assert %{status: :pending, checking: false} = info
    assert_in_delta seconds_until(info.next_check_at), 75, 1
  end

  test "a push goes through the state machine and resets the deadline" do
    start_engine()
    monitor = monitor_fixture(:push, %{interval_seconds: 60})
    start(monitor)

    assert {:ok, result} = push(monitor, {:up, %{message: "backup done", response_time_ms: 12}})
    assert %{status: :up, message: "backup done", response_time_ms: 12} = result
    assert_receive {:check_result, ^result}
    assert_receive {:status_changed, _, :pending, :up, ^result}

    info = Worker.info(monitor, @engine)
    assert info.status == :up
    # interval + default grace of 30 s
    assert_in_delta seconds_until(info.next_check_at), 90, 1

    # Without a ping the response time stays empty.
    assert {:ok, %{response_time_ms: nil}} = push(monitor, {:up, %{message: "OK"}})
    refute_receive {:status_changed, _, _, _, _}, 50
  end

  test "a missed deadline is down and opens an incident; the next push resolves it" do
    start_engine()
    monitor = monitor_fixture(:push, %{interval_seconds: 60, max_retries: 0})
    pid = start(monitor)

    assert {:ok, _} = push(monitor, {:up, %{message: "OK"}})
    assert_receive {:status_changed, _, :pending, :up, _}

    miss_deadline(pid)

    assert_receive {:check_result, %{status: :down, message: "No push received within 90 s"}},
                   2_000

    assert_receive {:status_changed, _, :up, :down, _}
    assert_receive {:incident_opened, %{from_status: :up, to_status: :down}}
    # Keeps reporting down every interval until a push arrives.
    assert_in_delta seconds_until(Worker.info(monitor, @engine).next_check_at), 60, 1

    assert {:ok, %{status: :up}} = push(monitor, {:up, %{message: "back"}})
    assert_receive {:status_changed, _, :down, :up, _}
    assert_receive {:incident_resolved, _}
  end

  test "missed deadlines and down pushes use the retries" do
    start_engine()

    monitor =
      monitor_fixture(:push, %{interval_seconds: 60, retry_interval_seconds: 20, max_retries: 1})

    pid = start(monitor)
    assert {:ok, %{status: :up}} = push(monitor, {:up, %{}})

    miss_deadline(pid)
    assert_receive {:check_result, %{status: :pending}}, 2_000
    # Retried after the retry interval.
    assert_in_delta seconds_until(Worker.info(monitor, @engine).next_check_at), 20, 1

    miss_deadline(pid)
    assert_receive {:check_result, %{status: :down}}, 2_000

    assert {:ok, %{status: :up}} = push(monitor, {:up, %{}})

    assert {:ok, %{status: :pending, message: "disk full"}} =
             push(monitor, {:down, %{message: "disk full"}})

    # After a push the deadline is the full interval again, even when pending.
    assert_in_delta seconds_until(Worker.info(monitor, @engine).next_check_at), 90, 1
    assert {:ok, %{status: :down}} = push(monitor, {:down, %{message: "disk full"}})
  end

  test "check_now does nothing for passive checks" do
    start_engine()
    monitor = monitor_fixture(:push)
    start(monitor)
    assert {:ok, _} = push(monitor, {:up, %{}})
    assert_receive {:check_result, _}

    :ok = Worker.check_now(monitor, @engine)
    refute_receive {:check_result, _}, 100
    assert Worker.info(monitor, @engine).status == :up
  end

  test "pushes during maintenance are recorded as maintenance" do
    start_engine(maintenance: AlwaysInMaintenance)
    monitor = monitor_fixture(:push)
    start(monitor)

    assert {:ok, %{status: :maintenance}} = push(monitor, {:down, %{message: "x"}})
    refute_receive {:status_changed, _, _, _, _}, 50
  end

  test "pushing to a monitor without a passive worker" do
    start_engine()
    assert {:error, :not_running} = push(monitor_fixture(:push), {:up, %{}})

    start_supervised!(FakeCheck)
    http = monitor_fixture(:http)
    start(http)
    assert {:error, :not_passive} = push(http, {:up, %{}})
  end

  test "is registered as the check for push monitors" do
    assert {:ok, Push} = Sentinelix.Checks.module_for(:push)
    assert Push.passive?()
  end
end
