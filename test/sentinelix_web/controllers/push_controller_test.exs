defmodule SentinelixWeb.PushControllerTest do
  # Uses the application's (default) monitoring engine.
  use SentinelixWeb.ConnCase, async: false

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Supervisor, as: Engine

  setup do
    monitor = monitor_fixture(:push, %{max_retries: 0})
    {:ok, _pid} = Engine.start_worker(monitor)
    on_exit(fn -> Engine.stop_worker(monitor) end)
    :ok = Monitoring.subscribe_monitor(monitor)
    %{monitor: monitor, token: monitor.settings.push_token}
  end

  test "GET records an up push without authentication", %{conn: conn, token: token} do
    conn = get(conn, ~p"/api/push/#{token}")

    assert json_response(conn, 200) == %{"ok" => true, "status" => "up"}
    assert_received {:check_result, %{status: :up, message: "OK", response_time_ms: nil}}
    assert_received {:status_changed, _, :pending, :up, _}
  end

  test "GET with status, msg and ping", %{conn: conn, monitor: monitor, token: token} do
    params = %{status: "down", msg: "backup failed", ping: "12.6"}
    conn = get(conn, ~p"/api/push/#{token}?#{params}")

    assert json_response(conn, 200) == %{"ok" => true, "status" => "down"}

    assert [%{status: :down, message: "backup failed", response_time_ms: 13}] =
             Monitoring.latest_results(monitor)

    assert_received {:incident_opened, %{message: "backup failed"}}
    assert Monitoring.worker_info(monitor).status == :down
  end

  test "POST with form or JSON params, without a CSRF token", %{conn: conn, token: token} do
    conn = post(conn, ~p"/api/push/#{token}", %{"status" => "up", "msg" => "posted"})
    assert json_response(conn, 200)["ok"]
    assert_received {:check_result, %{status: :up, message: "posted"}}

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/push/#{token}", ~s({"status": "down", "ping": 5}))

    assert json_response(conn, 200)["status"] == "down"
    assert_received {:check_result, %{status: :down, response_time_ms: 5}}
  end

  test "ignores an invalid ping", %{conn: conn, token: token} do
    conn = get(conn, ~p"/api/push/#{token}?ping=fast")
    assert json_response(conn, 200)["ok"]
    assert_received {:check_result, %{response_time_ms: nil}}
  end

  test "rejects an invalid status", %{conn: conn, token: token} do
    conn = get(conn, ~p"/api/push/#{token}?status=sideways")
    assert %{"ok" => false, "error" => _} = json_response(conn, 400)
    refute_received {:check_result, _}
  end

  test "unknown tokens are not found", %{conn: conn} do
    conn = get(conn, ~p"/api/push/not-a-real-token-at-all")
    assert %{"ok" => false} = json_response(conn, 404)
  end

  test "is rate limited per client IP", %{conn: conn, token: token} do
    {limit, period} = Application.fetch_env!(:sentinelix, Sentinelix.RateLimit)[:push]
    await_rate_limit_window(:push)
    # Use up the client's budget.
    {:allow, ^limit} = Sentinelix.RateLimit.hit({:push, conn.remote_ip}, period, limit, limit)

    conn = get(conn, ~p"/api/push/#{token}")
    assert json_response(conn, 429) == %{"ok" => false, "error" => "Rate limit exceeded"}
    assert [_retry_after] = get_resp_header(conn, "retry-after")
    refute_received {:check_result, _}

    conn = get(build_conn() |> Map.put(:remote_ip, unique_ip()), ~p"/api/push/#{token}")
    assert json_response(conn, 200)["ok"]
  end

  test "disabled monitors are not found", %{conn: conn, monitor: monitor, token: token} do
    {:ok, _} = Monitoring.toggle_monitor(monitor)
    Engine.stop_worker(monitor)

    conn = get(conn, ~p"/api/push/#{token}")
    assert json_response(conn, 404)["ok"] == false
  end

  test "a monitor without a running worker is unavailable", %{
    conn: conn,
    monitor: monitor,
    token: token
  } do
    Engine.stop_worker(monitor)

    conn = get(conn, ~p"/api/push/#{token}")
    assert json_response(conn, 503)["ok"] == false
  end
end
