defmodule SentinelixWeb.HealthControllerTest do
  use SentinelixWeb.ConnCase, async: true

  test "GET /healthz is 200 without authentication when the database answers", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 200) == %{"status" => "ok", "db" => "ok"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    # Not routed through the browser pipeline: no session cookie.
    assert conn.resp_cookies == %{}
  end

  test "GET /healthz is 503 when the database does not answer", %{conn: conn} do
    # A process that is not allowed to use the test's sandbox connection
    # gets no connection, like with a database that is down.
    test = self()
    spawn(fn -> send(test, {:conn, get(conn, ~p"/healthz")}) end)
    assert_receive {:conn, conn}, 5_000

    assert json_response(conn, 503) == %{"status" => "error", "db" => "error"}
  end
end
