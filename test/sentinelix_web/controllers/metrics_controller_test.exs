defmodule SentinelixWeb.MetricsControllerTest do
  use SentinelixWeb.ConnCase, async: false

  import Sentinelix.MonitoringFixtures

  @token "s3cret-metrics-token"

  defp put_token(token) do
    previous = Application.fetch_env(:sentinelix, :metrics_token)

    if token,
      do: Application.put_env(:sentinelix, :metrics_token, token),
      else: Application.delete_env(:sentinelix, :metrics_token)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sentinelix, :metrics_token, value)
        :error -> Application.delete_env(:sentinelix, :metrics_token)
      end
    end)
  end

  describe "without METRICS_TOKEN" do
    setup do: put_token(nil)

    test "the endpoint is disabled", %{conn: conn} do
      assert conn |> get(~p"/metrics") |> response(404)

      assert conn
             |> put_req_header("authorization", "Bearer anything")
             |> get(~p"/metrics")
             |> response(404)
    end
  end

  describe "with METRICS_TOKEN" do
    setup do: put_token(@token)

    test "requires the bearer token", %{conn: conn} do
      conn = get(conn, ~p"/metrics")
      assert response(conn, 401)
      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="metrics")]

      for header <- ["Bearer wrong", "Basic #{Base.encode64("user:#{@token}")}", @token] do
        assert build_conn()
               |> put_req_header("authorization", header)
               |> get(~p"/metrics")
               |> response(401)
      end
    end

    test "a logged in session is not enough", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      assert conn |> get(~p"/metrics") |> response(401)
    end

    test "renders Prometheus metrics with a valid token", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "API"})
      check_result_fixture(monitor, %{status: :up, response_time_ms: 120})

      conn =
        conn
        |> put_req_header("authorization", "bearer #{@token}")
        |> get(~p"/metrics")

      body = response(conn, 200)
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
      assert content_type =~ "version=0.0.4"

      labels = ~s(monitor_id="#{monitor.id}",monitor="API",type="http")
      assert body =~ "sentinelix_monitor_up{#{labels}} 1\n"
      assert body =~ "sentinelix_monitor_response_time_ms{#{labels}} 120\n"
      # Telemetry metrics from the Peep reporter
      assert body =~ "# TYPE sentinelix_repo_query_total_time_milliseconds histogram\n"
    end
  end
end
