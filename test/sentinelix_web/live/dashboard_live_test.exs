defmodule SentinelixWeb.DashboardLiveTest do
  # Not async: creating monitors broadcasts on the global "monitors" topic,
  # which other (async) tests subscribe to.
  use SentinelixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring

  test "GET / redirects to the login page when logged out", %{conn: conn} do
    assert conn |> get(~p"/") |> redirected_to() == ~p"/login"
  end

  describe "logged in" do
    setup :register_and_log_in_user

    test "renders the app shell and an empty state", %{conn: conn, user: user} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Sentinelix"

      {:ok, view, html} = live(conn)
      assert html =~ user.email
      assert has_element?(view, "#app-nav a[href='/monitors']", "Monitors")
      assert has_element?(view, "#app-nav a[href='/settings/users']")
      assert has_element?(view, "#app-nav a[aria-current='page']", "Dashboard")
      assert has_element?(view, "#empty-state", "No monitors yet")
      assert has_element?(view, "#counter-up", "0")
    end

    test "lists monitors with status, heartbeats and uptime", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Homepage", labels: %{"env" => "prod"}})
      paused = monitor_fixture(:http, %{name: "Paused one", enabled: false})
      empty = monitor_fixture(:tcp, %{name: "No results"})

      check_result_fixture(monitor, %{status: :up, response_time_ms: 42})
      check_result_fixture(monitor, %{status: :down, response_time_ms: 99})

      {:ok, view, _html} = live(conn, ~p"/")

      row = view |> element("#monitor-#{monitor.id}") |> render()
      assert row =~ "Homepage"
      assert row =~ "Down"
      assert row =~ "99 ms"
      assert row =~ "50.00%"
      assert has_element?(view, "#monitor-#{monitor.id} [data-label='env=prod']")
      assert has_element?(view, "#heartbeats-#{monitor.id} [data-status=up]")
      assert has_element?(view, "#heartbeats-#{monitor.id} [data-status=down]")

      assert view |> element("#monitor-#{paused.id}") |> render() =~ "Paused"
      empty_row = view |> element("#monitor-#{empty.id}") |> render()
      assert empty_row =~ "Pending"
      assert empty_row =~ "db.example.com:5432"

      assert has_element?(view, "#counter-down", "1")
      assert has_element?(view, "#counter-paused", "1")
      assert has_element?(view, "#counter-pending", "1")
    end

    test "updates in real time", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Homepage"})
      {:ok, view, _html} = live(conn, ~p"/")

      check_result_fixture(monitor, %{status: :down, response_time_ms: 503})
      row = view |> element("#monitor-#{monitor.id}") |> render()
      assert row =~ "Down"
      assert row =~ "503 ms"
      assert has_element?(view, "#counter-down", "1")

      Monitoring.broadcast_status_event(monitor, {:warning_raised, monitor, nil})
      assert view |> element("#monitor-#{monitor.id}") |> render() =~ "Warning"

      {:ok, renamed} = Monitoring.update_monitor(monitor, %{name: "Renamed"})
      assert view |> element("#monitor-#{monitor.id}") |> render() =~ "Renamed"

      {:ok, _} = Monitoring.toggle_monitor(renamed)
      assert view |> element("#monitor-#{monitor.id}") |> render() =~ "Paused"

      other = monitor_fixture(:cert, %{name: "New cert monitor"})
      assert has_element?(view, "#monitor-#{other.id}", "New cert monitor")

      {:ok, _} = Monitoring.delete_monitor(other)
      refute has_element?(view, "#monitor-#{other.id}")
    end

    test "filters by selector", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod", "legacy" => ""}})
      db = monitor_fixture(:tcp, %{name: "Database", labels: %{"env" => "internal"}})
      check_result_fixture(db, %{status: :down})

      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#filter-form", %{selector: "Env = prod"}) |> render_change()
      assert_patch(view, ~p"/?#{[selector: "env=prod"]}")
      assert has_element?(view, "#monitor-#{web.id}")
      refute has_element?(view, "#monitor-#{db.id}")

      # Automatic labels, pseudo-labels and several terms.
      {:ok, view, _html} = live(conn, ~p"/?#{[selector: "type=tcp, name~datab"]}")
      refute has_element?(view, "#monitor-#{web.id}")
      assert has_element?(view, "#monitor-#{db.id}")

      {:ok, view, _html} = live(conn, ~p"/?#{[selector: "env, !legacy"]}")
      refute has_element?(view, "#monitor-#{web.id}")
      assert has_element?(view, "#monitor-#{db.id}")

      {:ok, view, _html} = live(conn, ~p"/?#{[selector: "status=down"]}")
      refute has_element?(view, "#monitor-#{web.id}")
      assert has_element?(view, "#monitor-#{db.id}")

      # A monitor that recovers drops out of the "down" filter.
      check_result_fixture(db, %{status: :up})
      refute has_element?(view, "#monitor-#{db.id}")
      assert has_element?(view, "#monitors-empty")
    end

    test "shows selector errors inline", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod"}})

      {:ok, view, _html} = live(conn, ~p"/?#{[selector: "env=prod"]}")

      # While typing, an invalid selector keeps the last valid one's monitors.
      view |> form("#filter-form", %{selector: "env=prod, site="}) |> render_change()
      assert has_element?(view, "#selector-error", "expected a value at column 16")
      assert has_element?(view, "#selector[aria-invalid]")
      assert has_element?(view, "#monitor-#{web.id}")

      view |> form("#filter-form", %{selector: "env=prod"}) |> render_change()
      assert_patch(view, ~p"/?#{[selector: "env=prod"]}")
      refute has_element?(view, "#selector-error")

      # An invalid selector in the URL shows no monitors.
      {:ok, view, _html} = live(conn, ~p"/?#{[selector: "env in (prod"]}")
      assert has_element?(view, "#selector-error", ~s{expected "," or ")" at column 13})
      assert has_element?(view, "#selector[value='env in (prod']")
      refute has_element?(view, "#monitor-#{web.id}")

      {:ok, view, _html} = live(conn, "/?selector[]=env&q[]=x&label[]=y")
      assert has_element?(view, "#monitor-#{web.id}")
    end

    test "completes label keys and values, user and automatic", %{conn: conn} do
      monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod", "legacy" => ""}})
      monitor_fixture(:tcp, %{name: "Database", labels: %{"env" => "internal"}})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#selector-suggestions option[value='env=prod']")
      assert has_element?(view, "#selector-suggestions option[value='type=tcp']")
      assert has_element?(view, "#selector-suggestions option[value='status=down']")

      view |> form("#filter-form", %{selector: "legacy, host=db"}) |> render_change()

      assert has_element?(
               view,
               "#selector-suggestions option[value='legacy, host=db.example.com']"
             )

      refute has_element?(view, "#selector-suggestions option[value='legacy, env=prod']")
    end

    test "badges add terms, status counters toggle them", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod", "legacy" => ""}})
      db = monitor_fixture(:tcp, %{name: "Database", labels: %{"env" => "internal"}})

      {:ok, view, _html} = live(conn, ~p"/?#{[selector: "env"]}")
      view |> element("#monitor-#{web.id} a[data-label=legacy]") |> render_click()
      assert_patch(view, ~p"/?#{[selector: "env, legacy"]}")
      refute has_element?(view, "#monitor-#{db.id}")

      view |> element("#counter-pending") |> render_click()
      assert_patch(view, ~p"/?#{[selector: "env, legacy, status=pending"]}")
      assert has_element?(view, "#monitor-#{web.id}")

      # Another counter replaces the status, the same one removes it.
      view |> element("#counter-up") |> render_click()
      assert_patch(view, ~p"/?#{[selector: "env, legacy, status=up"]}")
      refute has_element?(view, "#monitor-#{web.id}")

      view |> element("#counter-up") |> render_click()
      assert_patch(view, ~p"/?#{[selector: "env, legacy"]}")

      view |> element("#clear-filters") |> render_click()
      assert_patch(view, ~p"/")
      assert has_element?(view, "#monitor-#{db.id}")
    end

    test "links from before selectors keep working", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod", "legacy" => ""}})
      db = monitor_fixture(:tcp, %{name: "Database", labels: %{"env" => "internal"}})
      check_result_fixture(db, %{status: :down})

      {:ok, view, _html} = live(conn, ~p"/?q=datab")
      assert has_element?(view, "#selector[value='name~datab']")
      refute has_element?(view, "#monitor-#{web.id}")
      assert has_element?(view, "#monitor-#{db.id}")

      {:ok, view, _html} = live(conn, ~p"/?status=down")
      refute has_element?(view, "#monitor-#{web.id}")
      assert has_element?(view, "#monitor-#{db.id}")

      {:ok, view, _html} = live(conn, ~p"/?label=env=prod")
      assert has_element?(view, "#monitor-#{web.id}")
      refute has_element?(view, "#monitor-#{db.id}")

      # A label without a value matches any value of its key.
      {:ok, view, _html} = live(conn, ~p"/?label=env")
      assert has_element?(view, "#monitor-#{web.id}")
      assert has_element?(view, "#monitor-#{db.id}")

      # The parameter of the tag filter that labels replaced.
      {:ok, view, _html} = live(conn, ~p"/?tag=legacy&status=pending")
      assert has_element?(view, "#selector[value='status=pending, legacy']")
      assert has_element?(view, "#monitor-#{web.id}")
      refute has_element?(view, "#monitor-#{db.id}")
    end
  end
end
