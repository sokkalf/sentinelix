defmodule Sentinelix.MetricsTest do
  use Sentinelix.DataCase, async: false

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.FakeCheck
  alias Sentinelix.Metrics
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Supervisor, as: Engine
  alias Sentinelix.Monitoring.Worker

  @engine __MODULE__.Engine

  setup do
    start_supervised!(FakeCheck)

    start_supervised!(
      {Engine,
       name: @engine, manager: false, jitter: 0, checks: %{http: FakeCheck, cert: FakeCheck}}
    )

    :ok
  end

  # Starts a worker and waits until its first check is fully processed.
  defp run(monitor, results) do
    FakeCheck.push(monitor, results)
    :ok = Monitoring.subscribe_monitor(monitor)
    {:ok, _pid} = Engine.start_worker(monitor, @engine)
    assert_receive {:check_result, _result}, 2_000
    # Synchronises with the worker: telemetry has been emitted.
    assert %{} = Worker.info(monitor, @engine)
    monitor
  end

  defp metrics, do: [engine: @engine] |> Metrics.monitor_metrics() |> IO.iodata_to_binary()

  defp labels(monitor),
    do: ~s(monitor_id="#{monitor.id}",monitor="#{monitor.name}",type="#{monitor.type}")

  test "reports up monitors from their worker" do
    monitor =
      run(monitor_fixture(:http, %{name: "Web"}), [{:up, %{response_time_ms: 42}}])

    output = metrics()

    assert output =~ "# TYPE sentinelix_monitor_up gauge\n"
    assert output =~ "sentinelix_monitor_up{#{labels(monitor)}} 1\n"
    assert output =~ "sentinelix_monitor_enabled{#{labels(monitor)}} 1\n"
    assert output =~ "sentinelix_monitor_response_time_ms{#{labels(monitor)}} 42\n"
    assert output =~ "sentinelix_monitor_warning{#{labels(monitor)}} 0\n"
    assert output =~ ~s(sentinelix_monitor_status{#{labels(monitor)},status="up"} 1\n)
    assert output =~ ~s(sentinelix_monitor_status{#{labels(monitor)},status="down"} 0\n)

    assert output =~
             ~r/sentinelix_monitor_last_check_timestamp_seconds\{#{labels(monitor)}\} \d+\n/
  end

  test "reports down monitors and warnings" do
    down = run(monitor_fixture(:http, %{max_retries: 0}), [{:down, %{message: "boom"}}])
    warn = run(monitor_fixture(), [{:up, %{warning: true, message: "careful"}}])

    output = metrics()

    assert output =~ "sentinelix_monitor_up{#{labels(down)}} 0\n"
    assert output =~ ~s(sentinelix_monitor_status{#{labels(down)},status="down"} 1\n)
    assert output =~ "sentinelix_monitor_warning{#{labels(warn)}} 1\n"
  end

  test "pending monitors have a status but no up gauge" do
    monitor = run(monitor_fixture(:http, %{max_retries: 2}), [{:down, %{message: "boom"}}])

    output = metrics()

    refute output =~ "sentinelix_monitor_up{#{labels(monitor)}}"
    assert output =~ ~s(sentinelix_monitor_status{#{labels(monitor)},status="pending"} 1\n)
  end

  test "falls back to the latest stored result without a running worker (e.g. right after boot)" do
    monitor = monitor_fixture()
    check_result_fixture(monitor, %{status: :down, response_time_ms: 7})
    never_checked = monitor_fixture()

    output = metrics()

    assert output =~ "sentinelix_monitor_up{#{labels(monitor)}} 0\n"
    assert output =~ "sentinelix_monitor_response_time_ms{#{labels(monitor)}} 7\n"
    refute output =~ "sentinelix_monitor_up{#{labels(never_checked)}}"

    assert output =~
             ~s(sentinelix_monitor_status{#{labels(never_checked)},status="pending"} 1\n)
  end

  test "reports maintenance from the latest result" do
    monitor = monitor_fixture()
    check_result_fixture(monitor, %{status: :maintenance})

    output = metrics()

    refute output =~ "sentinelix_monitor_up{#{labels(monitor)}}"
    assert output =~ ~s(sentinelix_monitor_status{#{labels(monitor)},status="maintenance"} 1\n)
  end

  test "disabled monitors are only reported as disabled" do
    monitor = monitor_fixture(:http, %{enabled: false})
    check_result_fixture(monitor, %{status: :up, response_time_ms: 5})

    output = metrics()

    assert output =~ "sentinelix_monitor_enabled{#{labels(monitor)}} 0\n"
    refute output =~ "sentinelix_monitor_up{#{labels(monitor)}}"
    refute output =~ "sentinelix_monitor_status{#{labels(monitor)}"
    refute output =~ "sentinelix_monitor_warning{#{labels(monitor)}}"
  end

  test "reports certificate days remaining and drops deleted monitors" do
    monitor = run(monitor_fixture(:cert), [{:up, %{meta: %{days_remaining: 12}}}])
    other = run(monitor_fixture(), [{:up, %{}}])

    output = metrics()
    assert output =~ "sentinelix_monitor_cert_days_remaining{#{labels(monitor)}} 12\n"
    refute output =~ "sentinelix_monitor_cert_days_remaining{#{labels(other)}}"

    :ok = Engine.stop_worker(monitor, @engine)
    {:ok, _} = Monitoring.delete_monitor(monitor)

    output = metrics()
    refute output =~ ~s(monitor_id="#{monitor.id}")
    refute output =~ "sentinelix_monitor_cert_days_remaining"
    assert output =~ "sentinelix_monitor_up{#{labels(other)}} 1\n"
  end

  test "a certificate check without days remaining clears the value" do
    monitor = run(monitor_fixture(:cert), [{:up, %{meta: %{days_remaining: 30}}}])
    assert metrics() =~ "sentinelix_monitor_cert_days_remaining{#{labels(monitor)}} 30\n"

    FakeCheck.push(monitor, [{:down, %{message: "connection refused"}}])
    :ok = Worker.check_now(monitor, @engine)
    assert_receive {:check_result, %{status: :down}}, 2_000
    assert %{} = Worker.info(monitor, @engine)

    refute metrics() =~ "sentinelix_monitor_cert_days_remaining{#{labels(monitor)}}"
  end

  test "reports monitor labels in an info metric only" do
    labelled =
      monitor_fixture(:http, %{
        enabled: false,
        labels: %{"env" => "prod", "team/owner" => "ops@example.com", "legacy" => ""}
      })

    plain = monitor_fixture(:http, %{enabled: false})

    output = metrics()

    assert output =~ "# TYPE sentinelix_monitor_labels gauge\n"

    assert output =~
             ~s(sentinelix_monitor_labels{#{labels(labelled)},label_env="prod",label_legacy="",label_team_owner="ops@example.com"} 1\n)

    assert output =~ "sentinelix_monitor_labels{#{labels(plain)}} 1\n"
    # Other metrics don't carry them.
    assert output =~ "sentinelix_monitor_enabled{#{labels(labelled)}} 0\n"
  end

  test "escapes label values" do
    monitor = monitor_fixture(:http, %{name: ~s(Say "hi" \\ there)})

    assert metrics() =~
             ~s(sentinelix_monitor_enabled{monitor_id="#{monitor.id}",monitor="Say \\"hi\\" \\\\ there",type="http"} 1\n)
  end

  test "export/1 includes the telemetry metrics" do
    run(monitor_fixture(), [{:up, %{}}])

    output = [engine: @engine] |> Metrics.export() |> IO.iodata_to_binary()

    assert output =~ "sentinelix_monitor_up{"
    assert output =~ "# TYPE sentinelix_checks_total counter\n"

    assert output =~
             ~r/sentinelix_checks_total\{error="none",monitor_type="http",status="up"\} \d+/

    assert output =~ "# TYPE sentinelix_check_duration_milliseconds histogram\n"
    assert output =~ "# TYPE sentinelix_monitor_status_changes_total counter\n"
    assert String.ends_with?(output, "# EOF\n")
  end
end
