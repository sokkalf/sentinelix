defmodule SentinelixWeb.Live.DashboardTest do
  use SentinelixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sentinelix.MonitoringFixtures

  test "GET / redirects to the login page when logged out", %{conn: conn} do
    assert conn |> get(~p"/") |> redirected_to() == ~p"/login"
  end

  describe "logged in" do
    setup :register_and_log_in_user

    test "GET / renders the dashboard", %{conn: conn, user: user} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Sentinelix"

      {:ok, _view, html} = live(conn)
      assert html =~ "Sentinelix"
      assert html =~ user.email
      assert html =~ "No monitors yet"
    end

    test "lists monitors with their latest result and updates live", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Homepage"})
      paused = monitor_fixture(:http, %{name: "Paused one", enabled: false})

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Homepage"
      assert view |> element("#monitor-#{monitor.id}") |> render() =~ "pending"
      assert view |> element("#monitor-#{paused.id}") |> render() =~ "paused"

      check_result_fixture(monitor, %{status: :down, message: "503 Service Unavailable"})
      html = view |> element("#monitor-#{monitor.id}") |> render()
      assert html =~ "down"
      assert html =~ "503 Service Unavailable"

      monitor_fixture(:cert, %{name: "New cert monitor"})
      assert render(view) =~ "New cert monitor"
    end
  end

  describe "monitor page" do
    setup :register_and_log_in_user

    test "renders a monitor without results", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Empty"})
      {:ok, _view, html} = live(conn, ~p"/monitors/#{monitor.id}")
      assert html =~ "Empty"
      assert html =~ "No checks yet"
    end

    test "renders results and updates live", %{conn: conn} do
      monitor = monitor_fixture(:cert, %{name: "Cert"})
      check_result_fixture(monitor, %{status: :up, response_time_ms: 10})

      {:ok, view, html} = live(conn, ~p"/monitors/#{monitor.id}")
      assert html =~ "example.com:443"
      assert html =~ "Average response time: 10 ms"

      check_result_fixture(monitor, %{status: :down, response_time_ms: 30, message: "expired"})
      html = render(view)
      assert html =~ "expired"
      assert html =~ "Average response time: 20 ms"
    end

    test "redirects for unknown monitors", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/monitors/0")
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/monitors/nope")
    end
  end
end
