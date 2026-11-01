defmodule SentinelixWeb.EventControllerTest do
  # Uses the application's (default) monitoring engine.
  use SentinelixWeb.ConnCase, async: false

  import Sentinelix.MonitoringFixtures
  import Sentinelix.RateLimitHelpers

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{Events, MonitorEvent}
  alias Sentinelix.Monitoring.Supervisor, as: Engine

  setup do
    {:ok, monitor} = monitor_fixture(:postgres) |> Monitoring.generate_event_token()
    :ok = Monitoring.subscribe_monitor(monitor)
    %{monitor: monitor, token: monitor.event_token}
  end

  test "POST records an info event without authentication or CSRF token",
       %{conn: conn, monitor: monitor, token: token} do
    conn =
      post(conn, ~p"/api/v1/events/#{token}", %{
        "title" => "Patroni on_role_change: db1 is now primary",
        "action" => "on_role_change",
        "role" => "primary",
        "cluster" => "pg-main"
      })

    assert json_response(conn, 201) == %{"ok" => true, "status" => "pending"}

    assert [%MonitorEvent{severity: :info} = event] = Events.list_events(monitor)

    assert event.metadata == %{
             "action" => "on_role_change",
             "role" => "primary",
             "cluster" => "pg-main"
           }

    assert_received {:event_recorded, _}
  end

  test "POST with a JSON body", %{conn: conn, monitor: monitor, token: token} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/v1/events/#{token}",
        Jason.encode!(%{title: "Disk 91% full", severity: "warning", key: "disk", used: 91})
      )

    assert %{"ok" => true} = json_response(conn, 201)
    assert [%{key: "disk", title: "Disk 91% full"}] = Events.active_warnings(monitor)
    assert [%{metadata: %{"used" => 91}}] = Events.list_events(monitor)
  end

  test "reports the resulting status of a running monitor (here a push monitor)", %{conn: conn} do
    {:ok, monitor} = monitor_fixture(:push) |> Monitoring.generate_event_token()
    {:ok, _pid} = Engine.start_worker(monitor)
    on_exit(fn -> Engine.stop_worker(monitor) end)
    {:ok, _} = Monitoring.receive_push(monitor.settings.push_token)
    path = ~p"/api/v1/events/#{monitor.event_token}"

    conn = post(conn, path, %{"title" => "Disk", "severity" => "warning"})
    assert json_response(conn, 201) == %{"ok" => true, "status" => "warning"}

    conn = post(build_conn(), path, %{"title" => "Disk ok", "severity" => "ok"})
    assert json_response(conn, 201) == %{"ok" => true, "status" => "up"}
  end

  test "invalid params are a bad request", %{conn: conn, monitor: monitor, token: token} do
    conn = post(conn, ~p"/api/v1/events/#{token}", %{"severity" => "critical"})

    assert json_response(conn, 400) == %{
             "ok" => false,
             "error" => "severity must be info, warning or ok; title can't be blank"
           }

    assert Events.list_events(monitor) == []
  end

  test "unknown tokens, disabled monitors and GET", %{conn: conn, monitor: monitor, token: token} do
    conn = post(conn, ~p"/api/v1/events/nope", %{"title" => "t"})

    assert json_response(conn, 404) == %{
             "ok" => false,
             "error" => "Monitor not found or not active"
           }

    {:ok, _} = Monitoring.toggle_monitor(monitor)
    conn = post(build_conn(), ~p"/api/v1/events/#{token}", %{"title" => "t"})
    assert json_response(conn, 404)["ok"] == false

    # A push token is not an event token.
    push = monitor_fixture(:push)
    conn = post(build_conn(), ~p"/api/v1/events/#{push.settings.push_token}", %{"title" => "t"})
    assert json_response(conn, 404)

    # POST only.
    assert get(build_conn(), ~p"/api/v1/events/#{token}").status == 404
  end

  test "a revoked token no longer works", %{conn: conn, monitor: monitor, token: token} do
    {:ok, _} = Monitoring.revoke_event_token(monitor)
    conn = post(conn, ~p"/api/v1/events/#{token}", %{"title" => "t"})
    assert json_response(conn, 404)
  end

  test "is rate limited per client IP", %{conn: conn, token: token} do
    {limit, period} = Application.fetch_env!(:sentinelix, Sentinelix.RateLimit)[:events]
    await_rate_limit_window(:events)

    {:allow, ^limit} = Sentinelix.RateLimit.hit({:events, conn.remote_ip}, period, limit, limit)

    conn = post(conn, ~p"/api/v1/events/#{token}", %{"title" => "t"})
    assert json_response(conn, 429) == %{"ok" => false, "error" => "Rate limit exceeded"}
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) > 0
  end
end
