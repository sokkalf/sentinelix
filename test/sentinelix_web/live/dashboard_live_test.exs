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

      check_result_fixture(monitor, %{status: :unreachable})
      assert view |> element("#monitor-#{monitor.id}") |> render() =~ "Unreachable"
      assert has_element?(view, "#counter-unreachable", "1")
      assert has_element?(view, "#counter-down", "0")

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

  describe "grouping" do
    setup :register_and_log_in_user

    defp group(id), do: "#groups section[data-group='#{id}']"
    defp header(id), do: group(id) <> " > div:first-child"

    defp group_ids(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#groups > section")
      |> LazyHTML.attribute("data-group")
    end

    test "groups by a label with summaries, problems first and expanded", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod"}})
      api = monitor_fixture(:http, %{name: "API", labels: %{"env" => "prod"}})
      dev = monitor_fixture(:http, %{name: "Dev", labels: %{"env" => "dev"}})
      loose = monitor_fixture(:tcp, %{name: "Loose"})

      check_result_fixture(web, %{status: :up})
      check_result_fixture(api, %{status: :up})
      check_result_fixture(api, %{status: :down})
      check_result_fixture(dev, %{status: :up})
      check_result_fixture(loose, %{status: :up})

      {:ok, view, _html} = live(conn, ~p"/?group=env")

      assert group_ids(view) == ["env=prod", "env=dev", "!env"]

      # The problem group: expanded, with its worst status, counts and uptime.
      assert has_element?(view, group("env=prod") <> "[data-open=true]")
      assert has_element?(view, header("env=prod") <> " [data-role=worst]", "Down")
      assert has_element?(view, header("env=prod") <> " [data-role=up]", "1/2 up")
      assert has_element?(view, header("env=prod") <> " [data-role=down]", "1 down")
      assert has_element?(view, header("env=prod") <> " [data-role=uptime]", "66.67%")
      assert has_element?(view, header("env=prod") <> " button[aria-expanded=true]")
      assert has_element?(view, group("env=prod") <> " #monitor-#{web.id}")
      assert has_element?(view, group("env=prod") <> " #monitor-#{api.id}")

      # All green: collapsed, without rows.
      assert has_element?(view, group("env=dev") <> "[data-open=false]")
      assert has_element?(view, header("env=dev") <> " [data-role=up]", "1/1 up")
      assert has_element?(view, header("env=dev") <> " button[aria-expanded=false]")
      refute has_element?(view, "#monitor-#{dev.id}")
      assert has_element?(view, header("!env"), "(none)")
      refute has_element?(view, "#monitor-#{loose.id}")

      # Automatic labels, sorted by name.
      {:ok, view, _html} = live(conn, ~p"/?group=type&sort=name")
      assert group_ids(view) == ["type=http", "type=tcp"]
    end

    test "nests groups by a second key", %{conn: conn} do
      a = monitor_fixture(:http, %{name: "A", labels: %{"service" => "api", "site" => "oslo"}})
      b = monitor_fixture(:http, %{name: "B", labels: %{"service" => "api", "site" => "bergen"}})
      check_result_fixture(a, %{status: :up})
      check_result_fixture(b, %{status: :pending})

      {:ok, view, _html} = live(conn, ~p"/?group=service,site")

      assert has_element?(view, header("service=api") <> " [data-role=pending]", "1 pending")
      assert has_element?(view, group("service=api,site=bergen") <> " #monitor-#{b.id}")
      assert has_element?(view, group("service=api,site=oslo") <> "[data-open=false]")
      refute has_element?(view, "#monitor-#{a.id}")
    end

    test "group-by and sort are kept in the URL with the selector", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod", "site" => "oslo"}})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#monitors #monitor-#{web.id}")
      assert has_element?(view, "#group-by-0 option[value=site]")
      assert has_element?(view, "#group-by-0 option[value=host]")
      refute has_element?(view, "#group-by-1")

      view |> form("#filter-form", %{selector: "env", group: ["site"]}) |> render_change()
      assert_patch(view, ~p"/?#{[selector: "env", group: "site"]}")
      assert has_element?(view, group("site=oslo"))

      view
      |> form("#filter-form", %{selector: "env", group: ["site", "env"], sort: "name"})
      |> render_change()

      assert_patch(view, ~p"/?#{[selector: "env", group: "site,env", sort: "name"]}")
      assert has_element?(view, group("site=oslo,env=prod"))

      # Counters, badges and Clear keep the grouping.
      view |> element("#counter-up") |> render_click()
      assert_patch(view, ~p"/?#{[selector: "env, status=up", group: "site,env", sort: "name"]}")

      view |> element("#clear-filters") |> render_click()
      assert_patch(view, ~p"/?#{[group: "site,env", sort: "name"]}")

      # Regrouping while the selector being typed is invalid.
      view |> form("#filter-form", %{selector: "env=", group: ["env"]}) |> render_change()
      assert_patch(view, ~p"/?#{[group: "env", sort: "name"]}")

      view |> form("#filter-form", %{selector: "", group: [""]}) |> render_change()
      assert_patch(view, ~p"/")
      assert has_element?(view, "#monitors #monitor-#{web.id}")
    end

    test "groups expand and collapse, remembered in the browser", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod"}})
      dev = monitor_fixture(:http, %{name: "Dev", labels: %{"env" => "dev"}})
      check_result_fixture(web, %{status: :up})
      check_result_fixture(dev, %{status: :down})

      {:ok, view, _html} = live(conn, ~p"/?group=env")
      refute has_element?(view, "#monitor-#{web.id}")

      view |> element(header("env=prod") <> " button") |> render_click()
      assert has_element?(view, group("env=prod") <> " #monitor-#{web.id}")

      assert_push_event(view, "dashboard:groups", %{
        groups: %{"env=prod" => %{"open" => true, "problems" => false}}
      })

      view |> element(header("env=dev") <> " button") |> render_click()
      refute has_element?(view, "#monitor-#{dev.id}")

      assert_push_event(view, "dashboard:groups", %{groups: groups})
      assert groups["env=dev"] == %{"open" => false, "problems" => true}

      view |> element("#expand-all") |> render_click()
      assert has_element?(view, "#monitor-#{dev.id}")
      assert_push_event(view, "dashboard:groups", %{groups: %{"env=prod" => _}})

      view |> element("#collapse-all") |> render_click()
      refute has_element?(view, "#monitor-#{web.id}")
      refute has_element?(view, "#monitor-#{dev.id}")

      # Restored when (re)connecting; invalid entries are ignored, and an
      # override set while the problem state was different doesn't apply.
      conn =
        put_connect_params(conn, %{
          "dashboard_groups" => %{
            "env=prod" => %{"open" => true, "problems" => false},
            "env=dev" => %{"open" => false, "problems" => false},
            "bogus" => "yes"
          }
        })

      {:ok, view, _html} = live(conn, ~p"/?group=env")
      assert has_element?(view, "#monitor-#{web.id}")
      assert has_element?(view, "#monitor-#{dev.id}")
    end

    test "group headers and order follow status changes", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod"}})
      api = monitor_fixture(:http, %{name: "API", labels: %{"env" => "prod"}})
      dev = monitor_fixture(:http, %{name: "Dev", labels: %{"env" => "dev"}})
      Enum.each([web, api, dev], &check_result_fixture(&1, %{status: :up}))

      {:ok, view, _html} = live(conn, ~p"/?group=env")
      assert group_ids(view) == ["env=dev", "env=prod"]
      refute has_element?(view, "#monitor-#{web.id}")

      check_result_fixture(web, %{status: :unreachable})
      assert group_ids(view) == ["env=prod", "env=dev"]
      assert has_element?(view, header("env=prod") <> " [data-role=worst]", "Unreachable")
      assert has_element?(view, header("env=prod") <> " [data-role=up]", "1/2 up")
      assert has_element?(view, header("env=prod") <> " [data-role=unreachable]", "1 unreachable")
      assert has_element?(view, header("env=prod") <> " [data-role=uptime]", "66.67%")
      assert has_element?(view, group("env=prod") <> " #monitor-#{web.id}", "Unreachable")

      check_result_fixture(web, %{status: :up})
      assert group_ids(view) == ["env=dev", "env=prod"]
      refute has_element?(view, "#monitor-#{web.id}")

      # A monitor whose label changes moves to its new group.
      view |> element("#expand-all") |> render_click()
      {:ok, _} = Monitoring.update_monitor(api, %{labels: %{"env" => "dev"}})
      assert has_element?(view, group("env=dev") <> " #monitor-#{api.id}")
      refute has_element?(view, group("env=prod") <> " #monitor-#{api.id}")
      assert has_element?(view, header("env=dev") <> " [data-role=up]", "2/2 up")

      {:ok, _} = Monitoring.delete_monitor(api)
      refute has_element?(view, "#monitor-#{api.id}")
      assert has_element?(view, header("env=dev") <> " [data-role=up]", "1/1 up")
    end

    # The LiveViewTest client re-renders its whole page per diff, which is
    # slow with hundreds of rows; the server side takes a few milliseconds
    # per check result here. So most of this runs with collapsed groups.
    test "many monitors: collapsed groups render no rows", %{conn: conn} do
      monitors =
        for i <- 1..250 do
          monitor_fixture(:http, %{
            name: "Monitor #{i}",
            labels: %{"site" => "site-#{rem(i, 25)}"}
          })
        end

      down = Enum.at(monitors, 7)
      other = Enum.at(monitors, 2)

      for monitor <- monitors do
        check_result_fixture(monitor, %{status: if(monitor == down, do: :down, else: :up)})
      end

      {:ok, view, _html} = live(conn, ~p"/?group=site")

      # Only the group with the down monitor is expanded and first.
      assert length(group_ids(view)) == 25
      assert hd(group_ids(view)) == "site=site-8"
      assert row_count(view) == 10
      assert has_element?(view, header("site=site-8") <> " [data-role=up]", "9/10 up")

      view |> element("#expand-all") |> render_click()
      assert row_count(view) == 250

      view |> element("#collapse-all") |> render_click()
      assert row_count(view) == 0

      # A collapsed group's header stays live; a group that gets a problem
      # expands and moves up.
      check_result_fixture(down, %{status: :up})
      assert has_element?(view, header("site=site-8") <> " [data-role=up]", "10/10 up")
      assert has_element?(view, header("site=site-8") <> " [data-role=uptime]", "90.91%")

      check_result_fixture(other, %{status: :down})
      assert hd(group_ids(view)) == "site=site-3"
      assert row_count(view) == 10
      assert has_element?(view, group("site=site-3") <> " #monitor-#{other.id}", "Down")

      check_result_fixture(other, %{status: :up})
      assert row_count(view) == 0
      assert has_element?(view, "#counter-up", "250")
    end
  end

  describe "layouts" do
    setup :register_and_log_in_user

    defp cell(id), do: "#matrix a[data-cell='#{id}']"

    test "the layout is chosen in the form and kept in the URL", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod"}})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#layout option[value=list][selected]")

      view |> form("#filter-form", %{selector: "env", layout: "grid"}) |> render_change()
      assert_patch(view, ~p"/?#{[selector: "env", layout: "grid"]}")
      assert has_element?(view, "#layout option[value=grid][selected]")
      assert has_element?(view, "#monitors a#monitor-#{web.id}[data-status=pending]")

      # Counters keep the layout; switching while the selector is invalid.
      view |> element("#counter-pending") |> render_click()
      assert_patch(view, ~p"/?#{[selector: "env, status=pending", layout: "grid"]}")

      view
      |> form("#filter-form", %{selector: "env=", layout: "list"})
      |> render_change()

      assert_patch(view, ~p"/?#{[selector: "env, status=pending"]}")
      assert has_element?(view, "#monitors #heartbeats-#{web.id}")
    end

    test "grid: a tile per monitor with its status, details and live updates", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod"}})
      db = monitor_fixture(:tcp, %{name: "Database", enabled: false})
      check_result_fixture(web, %{status: :up, response_time_ms: 42})

      {:ok, view, _html} = live(conn, ~p"/?layout=grid")

      tile = "#monitors a#monitor-#{web.id}"
      assert has_element?(view, tile <> "[href='/monitors/#{web.id}'][data-status=up]", "Web")
      assert has_element?(view, tile <> " .sr-only", "Up")
      assert has_element?(view, tile <> " .hero-check-circle-mini")
      assert has_element?(view, tile <> "[aria-describedby='monitor-#{web.id}-details']")
      assert has_element?(view, "#monitor-#{web.id}-details[role=tooltip]", "42 ms")
      assert has_element?(view, "#monitor-#{web.id}-details", "Uptime (24h): 100%")
      assert has_element?(view, "#monitor-#{db.id}[data-status=paused]", "Paused")
      refute has_element?(view, "[id^=heartbeats-]")

      check_result_fixture(web, %{status: :down, response_time_ms: 503})
      assert has_element?(view, tile <> "[data-status=down] .hero-x-circle-mini")
      assert has_element?(view, "#monitor-#{web.id}-details", "503 ms")
      assert has_element?(view, "#monitor-#{web.id}-details", "Uptime (24h): 50.00%")
    end

    test "grid: grouped and collapsed as in the list", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod"}})
      dev = monitor_fixture(:http, %{name: "Dev", labels: %{"env" => "dev"}})
      check_result_fixture(web, %{status: :up})
      check_result_fixture(dev, %{status: :down})

      {:ok, view, _html} = live(conn, ~p"/?group=env&layout=grid")
      assert has_element?(view, group("env=dev") <> " a#monitor-#{dev.id}[data-status=down]")
      refute has_element?(view, "#monitor-#{web.id}")

      view |> element(header("env=prod") <> " button") |> render_click()
      assert has_element?(view, group("env=prod") <> " a#monitor-#{web.id}[data-status=up]")
    end

    test "matrix: asks for two keys", %{conn: conn} do
      monitor_fixture(:http, %{name: "Web", labels: %{"service" => "api", "site" => "oslo"}})

      {:ok, view, _html} = live(conn, ~p"/?layout=matrix")
      assert has_element?(view, "#matrix-prompt label[for=group-by-0]", "rows")
      assert has_element?(view, "#group-by-0 option[value='']", "Rows by…")
      refute has_element?(view, "#matrix")
      refute has_element?(view, "[id^=monitor-]")

      view
      |> form("#filter-form", %{layout: "matrix", group: ["service"]})
      |> render_change()

      assert_patch(view, ~p"/?#{[group: "service", layout: "matrix"]}")
      assert has_element?(view, "#matrix-prompt label[for=group-by-1]", "columns")
      assert has_element?(view, "#group-by-1 option[value=site]", "columns by site")
      refute has_element?(view, "#groups")
      refute has_element?(view, "#expand-all")

      view
      |> form("#filter-form", %{layout: "matrix", group: ["service", "site"]})
      |> render_change()

      assert_patch(view, ~p"/?#{[group: "service,site", layout: "matrix"]}")
      refute has_element?(view, "#matrix-prompt")
      assert has_element?(view, "#matrix")
    end

    test "matrix: worst status and count per cell, live, cells link to their monitors",
         %{conn: conn} do
      a = monitor_fixture(:http, %{name: "A", labels: %{"service" => "api", "site" => "oslo"}})
      b = monitor_fixture(:http, %{name: "B", labels: %{"service" => "api", "site" => "oslo"}})

      c =
        monitor_fixture(:http, %{name: "C", labels: %{"service" => "api", "site" => "helsinki"}})

      d = monitor_fixture(:http, %{name: "D", labels: %{"service" => "web", "site" => "bergen"}})
      e = monitor_fixture(:http, %{name: "E", labels: %{"site" => "oslo"}})
      Enum.each([a, b, c, d, e], &check_result_fixture(&1, %{status: :up}))
      check_result_fixture(b, %{status: :down})

      {:ok, view, _html} = live(conn, ~p"/?group=service,site&layout=matrix")

      columns =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#matrix thead th[data-column]")
        |> LazyHTML.attribute("data-column")

      assert columns == ["site=bergen", "site=helsinki", "site=oslo"]

      assert has_element?(view, "#matrix tbody tr:first-child[data-row='service=api']")
      assert has_element?(view, cell("service=api,site=oslo") <> "[data-status=down]", "1/2")
      assert has_element?(view, cell("service=api,site=oslo") <> " .hero-x-circle-mini")
      assert has_element?(view, cell("service=api,site=oslo") <> " .sr-only", "api, oslo: Down")
      assert has_element?(view, cell("service=api,site=oslo") <> " [role=tooltip]", "1 down")
      assert has_element?(view, cell("service=api,site=helsinki") <> "[data-status=up]", "1")
      assert has_element?(view, cell("!service,site=oslo"), "1")

      # Empty cells: web has no monitors in oslo or helsinki.
      assert has_element?(view, "#matrix tr[data-row='service=web'] [data-empty]", "No monitors")
      refute has_element?(view, cell("service=web,site=oslo"))
      refute has_element?(view, "[id^=monitor-]")

      check_result_fixture(b, %{status: :up})
      assert has_element?(view, cell("service=api,site=oslo") <> "[data-status=up]", "2")

      # A cell shows its monitors in the list.
      view |> element(cell("service=api,site=oslo")) |> render_click()
      assert_patch(view, ~p"/?#{[selector: "service=api, site=oslo"]}")
      assert has_element?(view, "#monitors #monitor-#{a.id}")
      assert has_element?(view, "#monitors #monitor-#{b.id}")
      refute has_element?(view, "#monitor-#{e.id}")

      # Headers too, and "(none)" adds a !key term to the selector.
      {:ok, view, _html} = live(conn, ~p"/?group=service,site&layout=matrix")
      view |> element(cell("!service,site=oslo")) |> render_click()
      assert_patch(view, ~p"/?#{[selector: "!service, site=oslo"]}")
      assert has_element?(view, "#monitor-#{e.id}")
      refute has_element?(view, "#monitor-#{a.id}")

      {:ok, view, _html} = live(conn, ~p"/?group=service,site&layout=matrix")
      view |> element("#matrix th[data-column='site=helsinki'] a") |> render_click()
      assert_patch(view, ~p"/?#{[selector: "site=helsinki"]}")
    end

    test "many monitors fit a grid", %{conn: conn} do
      for i <- 1..200, do: monitor_fixture(:http, %{name: "Monitor #{i}"})

      {:ok, view, _html} = live(conn, ~p"/?layout=grid")

      tiles =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#monitors > a[data-status]")

      assert Enum.count(tiles) == 200
    end
  end

  defp row_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^=monitor-]")
    |> Enum.count()
  end
end
