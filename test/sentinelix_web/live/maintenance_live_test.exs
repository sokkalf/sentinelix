defmodule SentinelixWeb.MaintenanceLiveTest do
  # Maintenance windows are cached and broadcast globally.
  use SentinelixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Sentinelix.MaintenanceFixtures
  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Maintenance

  setup :reset_maintenance_cache

  test "requires a login", %{conn: conn} do
    assert conn |> get(~p"/maintenance") |> redirected_to() == ~p"/login"
  end

  describe "logged in" do
    setup :register_and_log_in_user

    test "shows the navigation entry and an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/maintenance")
      assert has_element?(view, "#app-nav a[aria-current='page']", "Maintenance")
      assert has_element?(view, "#no-windows")
    end

    test "lists windows with their schedule, monitors and status", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Homepage"})
      active = window_fixture(%{title: "Upgrade", monitor_ids: [monitor.id]})

      {:ok, weekly} =
        Maintenance.create_window(%{
          title: "Weekly patching",
          all_monitors: true,
          recurrence: :weekly,
          weekdays: [2, 4],
          start_time: ~T[22:00:00],
          duration_minutes: 90,
          timezone: "Europe/Oslo"
        })

      {:ok, view, _html} = live(conn, ~p"/maintenance")

      assert has_element?(view, "#window-#{active.id}", "Upgrade")
      assert has_element?(view, "#window-#{active.id}", "Homepage")
      assert has_element?(view, "#window-status-#{active.id}", "Active")
      assert has_element?(view, "#window-#{weekly.id}", "Tue, Thu at 22:00 for 1h 30m")
      assert has_element?(view, "#window-#{weekly.id}", "Europe/Oslo")
      assert has_element?(view, "#window-#{weekly.id}", "All monitors")
    end

    test "disables, enables and deletes windows", %{conn: conn} do
      window = window_fixture(%{all_monitors: true, title: "Upgrade"})
      {:ok, view, _html} = live(conn, ~p"/maintenance")

      view |> element("#toggle-window-#{window.id}") |> render_click()
      assert has_element?(view, "#window-status-#{window.id}", "Disabled")
      refute Maintenance.active?(monitor_fixture(), DateTime.utc_now())

      view |> element("#toggle-window-#{window.id}") |> render_click()
      assert has_element?(view, "#window-status-#{window.id}", "Active")

      view |> element("#delete-window-#{window.id}") |> render_click()
      refute has_element?(view, "#window-#{window.id}")
      assert Maintenance.list_windows() == []
    end

    test "updates when windows change elsewhere", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/maintenance")
      window = window_fixture(%{all_monitors: true, title: "Elsewhere"})
      assert render(view) =~ "Elsewhere"
      assert has_element?(view, "#window-#{window.id}")
    end

    test "creates a one-off window in a time zone", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Homepage"})
      {:ok, view, _html} = live(conn, ~p"/maintenance/new")

      assert has_element?(view, "#once-fields")

      view
      |> form("#window-form",
        window: %{
          title: "",
          timezone: "Europe/Oslo",
          local_starts_at: "2026-11-01T22:00",
          local_ends_at: "2026-11-01T21:00"
        }
      )
      |> render_submit()

      assert has_element?(view, "#window-form", "can't be blank")
      assert has_element?(view, "#window-form", "must be after the start")
      assert has_element?(view, "#window-form", "select at least one monitor")

      {:ok, _view, html} =
        view
        |> form("#window-form",
          window: %{
            title: "DB upgrade",
            timezone: "Europe/Oslo",
            local_starts_at: "2026-11-01T22:00",
            local_ends_at: "2026-11-01T23:30",
            monitor_ids: ["#{monitor.id}"]
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/maintenance")

      assert html =~ "DB upgrade"
      assert html =~ "2026-11-01 22:00 – 2026-11-01 23:30"

      assert [window] = Maintenance.list_windows()
      assert window.starts_at == ~U[2026-11-01 21:00:00Z]
      assert window.ends_at == ~U[2026-11-01 22:30:00Z]
      assert Enum.map(window.monitors, & &1.id) == [monitor.id]
    end

    test "creates a weekly window for all monitors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/maintenance/new")

      view |> form("#window-form", window: %{recurrence: "weekly"}) |> render_change()
      assert has_element?(view, "#recurring-fields")
      assert has_element?(view, "#window-weekdays")
      refute has_element?(view, "#once-fields")

      {:ok, _view, _html} =
        view
        |> form("#window-form",
          window: %{
            title: "Patching",
            recurrence: "weekly",
            timezone: "Etc/UTC",
            weekdays: ["", "6", "7"],
            start_time: "03:00",
            duration_minutes: "120",
            all_monitors: "true"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/maintenance")

      assert [window] = Maintenance.list_windows()
      assert %{recurrence: :weekly, weekdays: [6, 7], start_time: ~T[03:00:00]} = window
      assert window.all_monitors
    end

    test "edits a window", %{conn: conn} do
      a = monitor_fixture(:http, %{name: "A"})
      b = monitor_fixture(:http, %{name: "B"})

      {:ok, window} =
        Maintenance.create_window(%{
          title: "Upgrade",
          timezone: "Europe/Oslo",
          starts_at: ~U[2026-11-01 21:00:00Z],
          ends_at: ~U[2026-11-01 22:00:00Z],
          monitor_ids: [a.id]
        })

      {:ok, view, html} = live(conn, ~p"/maintenance/#{window.id}/edit")
      # Shown in the window's time zone.
      assert html =~ "2026-11-01T22:00"
      assert has_element?(view, "#monitor-#{a.id}[checked]")

      {:ok, _view, _html} =
        view
        |> form("#window-form",
          window: %{title: "Renamed", monitor_ids: ["#{b.id}"], local_ends_at: "2026-11-01T23:30"}
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/maintenance")

      window = Maintenance.get_window!(window.id)
      assert window.title == "Renamed"
      assert window.ends_at == ~U[2026-11-01 22:30:00Z]
      assert Enum.map(window.monitors, & &1.id) == [b.id]
    end

    test "redirects for unknown windows", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/maintenance"}}} =
               live(conn, ~p"/maintenance/123456/edit")
    end
  end

  describe "maintenance badges" do
    setup :register_and_log_in_user

    test "on the dashboard, monitor list and detail page", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Homepage"})
      other = monitor_fixture(:http, %{name: "Other"})

      {:ok, dashboard, _html} = live(conn, ~p"/")
      {:ok, index, _html} = live(conn, ~p"/monitors")
      {:ok, show, _html} = live(conn, ~p"/monitors/#{monitor.id}")
      refute has_element?(dashboard, "#maintenance-#{monitor.id}")
      refute has_element?(show, "#monitor-maintenance")

      # Badges appear live when a window starts.
      window = window_fixture(%{title: "Upgrade", monitor_ids: [monitor.id]})

      assert has_element?(dashboard, "#maintenance-#{monitor.id}", "Maintenance")
      refute has_element?(dashboard, "#maintenance-#{other.id}")
      assert has_element?(index, "#maintenance-#{monitor.id}[title='In maintenance: Upgrade']")
      assert has_element?(show, "#monitor-maintenance")

      {:ok, _} = Maintenance.delete_window(window)
      refute has_element?(dashboard, "#maintenance-#{monitor.id}")
      refute has_element?(index, "#maintenance-#{monitor.id}")
      refute has_element?(show, "#monitor-maintenance")

      # And on first render.
      window_fixture(%{all_monitors: true})
      {:ok, show, _html} = live(conn, ~p"/monitors/#{other.id}")
      assert has_element?(show, "#monitor-maintenance")
    end
  end
end
