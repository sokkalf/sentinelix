defmodule SentinelixWeb.PostgresPasswordTest do
  @moduledoc """
  The password of a PostgreSQL monitor must never show up in check results,
  status events, telemetry, logs or rendered pages.
  """

  # Not async: runs a monitoring engine and raises the global log level.
  use SentinelixWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Sentinelix.MonitoringFixtures
  import Sentinelix.StatusPagesFixtures

  alias Sentinelix.Checks
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Supervisor, as: Engine
  alias Sentinelix.Repo

  @engine __MODULE__.Engine

  setup :register_and_log_in_user

  setup do
    start_supervised!(
      {Engine, name: @engine, manager: false, jitter: 0, checks: %{postgres: Checks.Postgres}}
    )

    handler = {__MODULE__, self()}

    :telemetry.attach_many(
      handler,
      [[:sentinelix, :check, :stop], [:sentinelix, :monitor, :status_changed]],
      &__MODULE__.forward_telemetry/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  def forward_telemetry(event, measurements, metadata, test_pid),
    do: send(test_pid, {:telemetry, event, measurements, metadata})

  # Logs everything (including Ecto's queries) while `fun` runs.
  defp capture_debug_log(fun) do
    level = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug], fun)
    after
      Logger.configure(level: level)
    end
  end

  defp postgres_monitor(password, settings) do
    config = Repo.config()

    monitor_fixture(:postgres, %{
      name: "DB",
      timeout_ms: 5_000,
      secrets: %{password: password},
      settings:
        Map.merge(
          %{
            host: config[:hostname] || "localhost",
            port: config[:port] || 5432,
            database: config[:database],
            username: config[:username],
            ssl_mode: "disable"
          },
          settings
        )
    })
  end

  defp run_check(monitor) do
    :ok = Monitoring.subscribe_monitor(monitor)
    {:ok, _pid} = Engine.start_worker(monitor, @engine)

    assert_receive {:check_result, result}, 5_000
    assert_receive {:telemetry, [:sentinelix, :check, :stop], _, stop_metadata}, 5_000

    assert_receive {:incident_opened, incident}, 5_000
    assert_receive {:status_changed, _monitor, :pending, :down, _result} = changed, 5_000

    assert_receive {:telemetry, [:sentinelix, :monitor, :status_changed], _, changed_metadata},
                   5_000

    {result, [stop_metadata, incident, changed, changed_metadata]}
  end

  test "a failed check doesn't leak the password", %{conn: conn} do
    password = "pw-CANARY-#{System.unique_integer([:positive])}"

    log =
      capture_debug_log(fn ->
        for settings <- [
              # Authentication fails with the server's message.
              %{},
              # The connection is refused.
              %{host: "127.0.0.1", port: 1}
            ] do
          monitor = postgres_monitor(password, settings)

          {result, events} = run_check(monitor)
          assert result.status == :down
          assert result.message =~ "Connection failed"
          refute inspect(result) =~ password
          refute inspect(events, limit: :infinity, printable_limit: :infinity) =~ password
          refute inspect(Monitoring.get_monitor!(monitor.id)) =~ password

          for page <- [
                ~p"/monitors",
                ~p"/monitors/#{monitor}",
                ~p"/monitors/#{monitor}/edit",
                ~p"/monitors/#{monitor}/clone"
              ] do
            {:ok, _view, html} = live(conn, page)
            refute html =~ password, "#{page} renders the password"
          end

          status_page = published_page_fixture([monitor], %{show_details: true})
          {:ok, _view, html} = live(build_conn(), ~p"/status/#{status_page.slug}")
          assert html =~ "Connection failed"
          refute html =~ password

          Engine.stop_worker(monitor, @engine)
        end
      end)

    # Query logging is on; writes changing secrets are not logged.
    assert log =~ "INSERT INTO \"check_results\""
    refute log =~ "INSERT INTO \"monitors\""
    refute log =~ password
  end
end
