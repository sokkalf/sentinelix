defmodule SentinelixWeb.StatusPageMaintenanceTest do
  # Not async: maintenance windows are cached globally.
  use SentinelixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Sentinelix.MaintenanceFixtures
  import Sentinelix.MonitoringFixtures
  import Sentinelix.StatusPagesFixtures

  alias Sentinelix.{Maintenance, StatusPages}

  setup :reset_maintenance_cache

  test "monitors in an active window are in maintenance, not an outage", %{conn: conn} do
    down = monitor_fixture(:http, %{name: "Down one"})
    up = monitor_fixture(:http, %{name: "Fine"})
    elsewhere = monitor_fixture(:http, %{name: "Not on the page"})
    check_result_fixture(down, %{status: :down})
    check_result_fixture(up, %{status: :up})

    window =
      window_fixture(%{
        title: "Database upgrade",
        description: "internal: db-7.lan",
        monitor_ids: [down.id]
      })

    other_window = window_fixture(%{title: "Other work", monitor_ids: [elsewhere.id]})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    scheduled =
      window_fixture(%{
        title: "Network change",
        starts_at: DateTime.add(now, 2, :day),
        ends_at: DateTime.add(now, 50, :hour),
        monitor_ids: [up.id]
      })

    far_away =
      window_fixture(%{
        title: "Far away",
        starts_at: DateTime.add(now, 30, :day),
        ends_at: DateTime.add(now, 31, :day),
        monitor_ids: [up.id]
      })

    page = published_page_fixture([down, up])
    [group] = StatusPages.get_status_page!(page.id).groups

    {:ok, view, html} = live(conn, ~p"/status/#{page.slug}")

    assert has_element?(view, "#overall-status[data-status=maintenance]")
    assert has_element?(view, "#monitor-#{group.id}-#{down.id}[data-status=maintenance]")
    assert has_element?(view, "#maintenance-#{window.id}", "In progress")
    assert has_element?(view, "#maintenance-#{window.id}", "Down one")
    assert has_element?(view, "#maintenance-#{scheduled.id}", "Scheduled")
    refute has_element?(view, "#maintenance-#{other_window.id}")
    refute has_element?(view, "#maintenance-#{far_away.id}")
    # descriptions are details
    refute html =~ "db-7.lan"

    # live: the window ends
    {:ok, _} = Maintenance.delete_window(window)
    assert has_element?(view, "#overall-status[data-status=partial_outage]")

    refute has_element?(view, "#maintenance-#{window.id}")
  end

  test "shows window descriptions when the page enables details", %{conn: conn} do
    monitor = monitor_fixture()
    window_fixture(%{title: "Upgrade", description: "Upgrading to v2", monitor_ids: [monitor.id]})
    page = published_page_fixture([monitor], %{show_details: true})

    {:ok, _view, html} = live(conn, ~p"/status/#{page.slug}")
    assert html =~ "Upgrading to v2"
  end
end
