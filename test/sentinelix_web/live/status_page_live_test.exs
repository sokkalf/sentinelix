defmodule SentinelixWeb.StatusPageLiveTest do
  use SentinelixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sentinelix.MonitoringFixtures
  import Sentinelix.StatusPagesFixtures

  alias Sentinelix.{Monitoring, StatusPages}

  @secret_url "https://secret-internal.example.com/health"

  describe "public page" do
    test "is reachable without logging in", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Website"})
      check_result_fixture(monitor, %{status: :up})

      page =
        published_page_fixture([monitor], %{
          title: "Acme status",
          description: "Our services",
          footer_text: "Contact ops"
        })

      # Taken before rendering: if the page is rendered just after midnight
      # (UTC), its last 90 days still include this date.
      today = Date.utc_today()
      {:ok, view, html} = live(conn, ~p"/status/#{page.slug}")

      assert html =~ "Acme status"
      assert html =~ "Our services"
      assert html =~ "Contact ops"
      assert html =~ "Website"

      assert has_element?(
               view,
               "#overall-status[data-status=operational]",
               "All systems operational"
             )

      assert has_element?(view, "[data-status=operational]", "Operational")
      assert has_element?(view, "[id^=days-] [data-date='#{today}']")
      assert has_element?(view, "#no-incidents")
      # no app shell
      refute has_element?(view, "#app-nav")
      refute html =~ "Log out"
    end

    test "is a 404 for unknown slugs and unpublished pages", %{conn: conn} do
      draft = status_page_fixture(%{published: false})

      assert_error_sent 404, fn -> get(conn, ~p"/status/#{draft.slug}") end
      assert_error_sent 404, fn -> get(conn, ~p"/status/does-not-exist") end
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/status/#{draft.slug}") end
    end

    test "does not leak monitor targets or error messages", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "API", settings: %{url: @secret_url}})
      tcp = monitor_fixture(:tcp, %{name: "DB", settings: %{host: "db.secret.lan", port: 5432}})
      check_result_fixture(monitor, %{status: :down, message: "connection refused 10.0.0.7"})

      incident_fixture(monitor, %{message: "HTTP 500 from #{@secret_url}"})
      page = published_page_fixture([monitor, tcp])

      {:ok, view, html} = live(conn, ~p"/status/#{page.slug}")

      assert html =~ "API"
      refute html =~ "secret"
      refute html =~ "10.0.0.7"
      refute html =~ "HTTP 500"

      # nor in live updates
      check_result_fixture(monitor, %{status: :down, message: "timeout at 10.0.0.8"})
      refute render(view) =~ "10.0.0.8"
    end

    test "shows targets and messages when the page enables details", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "API", settings: %{url: @secret_url}})
      check_result_fixture(monitor, %{status: :down, message: "connection refused"})
      page = published_page_fixture([monitor], %{show_details: true})

      {:ok, _view, html} = live(conn, ~p"/status/#{page.slug}")
      assert html =~ @secret_url
      assert html =~ "connection refused"
    end

    test "shows outages, open incidents and incident history", %{conn: conn} do
      down = monitor_fixture(:http, %{name: "Down one"})
      flaky = monitor_fixture(:http, %{name: "Flaky"})
      up = monitor_fixture(:http, %{name: "Fine"})
      paused = monitor_fixture(:http, %{name: "Paused", enabled: false})
      check_result_fixture(down, %{status: :down})
      check_result_fixture(flaky, %{status: :up})
      check_result_fixture(up, %{status: :up})
      incident = incident_fixture(flaky)

      page = published_page_fixture([down, flaky, up, paused])
      [group] = StatusPages.get_status_page!(page.id).groups

      {:ok, view, _html} = live(conn, ~p"/status/#{page.slug}")

      assert has_element?(view, "#overall-status[data-status=partial_outage]", "Partial outage")
      assert has_element?(view, "#monitor-#{group.id}-#{down.id}[data-status=outage]")
      assert has_element?(view, "#monitor-#{group.id}-#{flaky.id}[data-status=degraded]")
      assert has_element?(view, "#monitor-#{group.id}-#{paused.id}[data-status=paused]")
      assert has_element?(view, "#incident-#{incident.id}", "Ongoing")
    end

    test "all monitors down is a major outage", %{conn: conn} do
      monitor = monitor_fixture()
      check_result_fixture(monitor, %{status: :down})
      page = published_page_fixture([monitor])

      {:ok, view, _html} = live(conn, ~p"/status/#{page.slug}")
      assert has_element?(view, "#overall-status[data-status=major_outage]", "Major outage")
    end

    test "monitors in maintenance are not an outage", %{conn: conn} do
      monitor = monitor_fixture()
      other = monitor_fixture()
      check_result_fixture(monitor, %{status: :maintenance})
      check_result_fixture(other, %{status: :up})
      page = published_page_fixture([monitor, other])

      {:ok, view, _html} = live(conn, ~p"/status/#{page.slug}")
      assert has_element?(view, "#overall-status[data-status=maintenance]")
    end

    test "unreachable monitors are shown as such and count as an outage", %{conn: conn} do
      host = monitor_fixture(:ping)
      monitor = monitor_fixture(:http, %{parent_id: host.id})
      other = monitor_fixture()
      check_result_fixture(monitor, %{status: :up})
      check_result_fixture(monitor, %{status: :unreachable})
      check_result_fixture(other, %{status: :up})
      page = published_page_fixture([monitor, other])
      [group] = StatusPages.get_status_page!(page.id).groups

      {:ok, view, _html} = live(conn, ~p"/status/#{page.slug}")
      row = "#monitor-#{group.id}-#{monitor.id}"
      assert has_element?(view, "#{row}[data-status=unreachable]", "Unreachable")
      assert has_element?(view, "#overall-status[data-status=partial_outage]")
      # Unreachable time is downtime.
      assert has_element?(view, row, "50.00%")

      check_result_fixture(monitor, %{status: :unreachable})
      assert has_element?(view, row, "33.33%")
    end

    test "updates live", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Website"})
      check_result_fixture(monitor, %{status: :up})
      page = published_page_fixture([monitor])

      {:ok, view, _html} = live(conn, ~p"/status/#{page.slug}")
      assert has_element?(view, "#overall-status[data-status=operational]")

      check_result_fixture(monitor, %{status: :down})
      assert has_element?(view, "#overall-status[data-status=major_outage]")

      incident = incident_fixture(monitor)
      assert has_element?(view, "#incident-#{incident.id}", "Ongoing")
      {:ok, _} = Monitoring.resolve_incident(incident)
      assert has_element?(view, "#incident-#{incident.id}", "Resolved")

      {:ok, _} = Monitoring.update_monitor(monitor, %{name: "Homepage"})
      assert render(view) =~ "Homepage"

      # configuration changes reload the page
      [group] = StatusPages.get_status_page!(page.id).groups
      {:ok, _} = StatusPages.update_group(group, %{name: "Web"})
      assert has_element?(view, "#group-#{group.id}", "Web")

      # unpublishing reloads into a 404
      {:ok, page} = StatusPages.update_status_page(page, %{published: false})
      assert_redirect(view, ~p"/status/#{page.slug}")
    end

    test "follows a slug change", %{conn: conn} do
      page = status_page_fixture(%{published: true})
      {:ok, view, html} = live(conn, ~p"/status/#{page.slug}")
      assert html =~ "No services are listed"

      {:ok, _} = StatusPages.update_status_page(page, %{slug: "renamed-#{page.id}"})
      assert_redirect(view, ~p"/status/renamed-#{page.id}")
    end
  end

  describe "admin logged out" do
    test "requires a logged in user", %{conn: conn} do
      assert conn |> get(~p"/status-pages") |> redirected_to() == ~p"/login"
      assert conn |> get(~p"/status-pages/1") |> redirected_to() == ~p"/login"
    end
  end

  describe "admin" do
    setup :register_and_log_in_user

    test "lists pages and links them in the navigation", %{conn: conn} do
      status_page_fixture(%{title: "Public one", slug: "public-one", published: true})
      status_page_fixture(%{title: "Draft one", slug: "draft-one"})

      {:ok, view, html} = live(conn, ~p"/status-pages")
      assert has_element?(view, "#app-nav a[aria-current='page']", "Status pages")
      assert html =~ "Public one"
      assert html =~ "Draft one"
      assert has_element?(view, "a[href='/status/public-one']")
      refute has_element?(view, "a[href='/status/draft-one']")
    end

    test "creates a page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/status-pages")
      assert has_element?(view, "#no-status-pages")
      view |> element("#new-status-page") |> render_click()
      assert_patch(view, ~p"/status-pages/new")

      html =
        view |> form("#status-page-form", status_page: %{title: "Acme Prod"}) |> render_change()

      assert html =~ "/status/acme-prod"

      assert view
             |> form("#status-page-form", status_page: %{title: "X", slug: "Bad slug"})
             |> render_submit() =~ "may only contain"

      {:ok, _view, html} =
        view
        |> form("#status-page-form", status_page: %{title: "Acme Prod", slug: ""})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Status page created"
      assert html =~ "Acme Prod"
      assert [%{page: %{slug: "acme-prod", published: false}}] = StatusPages.list_status_pages()
    end

    test "manages groups and monitors", %{conn: conn} do
      a = monitor_fixture(:http, %{name: "Alpha"})
      b = monitor_fixture(:http, %{name: "Beta"})
      page = status_page_fixture()

      {:ok, view, _html} = live(conn, ~p"/status-pages/#{page.id}")
      assert has_element?(view, "#no-groups")

      view |> form("#new-group-form", group: %{name: ""}) |> render_submit()
      refute has_element?(view, "[id^=group-]")

      view |> form("#new-group-form", group: %{name: "Websites"}) |> render_submit()
      view |> form("#new-group-form", group: %{name: "Backend"}) |> render_submit()
      [web, backend] = StatusPages.get_status_page!(page.id).groups
      assert web.name == "Websites"

      # add monitors
      view |> form("#add-monitor-#{web.id}", monitor_id: a.id) |> render_submit()
      view |> form("#add-monitor-#{web.id}", monitor_id: b.id) |> render_submit()
      refute has_element?(view, "#add-monitor-#{web.id}")
      assert monitor_names(page, web) == ["Alpha", "Beta"]

      # reorder monitors
      [_pm_a, pm_b] = group(page, web).page_monitors
      assert has_element?(view, "#page-monitor-#{pm_b.id}-down[disabled]")
      view |> element("#page-monitor-#{pm_b.id}-up") |> render_click()
      assert monitor_names(page, web) == ["Beta", "Alpha"]

      # remove a monitor
      view |> element("#remove-page-monitor-#{pm_b.id}") |> render_click()
      assert monitor_names(page, web) == ["Alpha"]

      # reorder, rename and delete groups
      view |> element("#group-#{backend.id}-up") |> render_click()

      assert Enum.map(StatusPages.get_status_page!(page.id).groups, & &1.name) == [
               "Backend",
               "Websites"
             ]

      view |> form("#rename-group-#{web.id}", name: "Web") |> render_submit()
      assert group(page, web).name == "Web"

      view |> element("#delete-group-#{backend.id}") |> render_click()
      assert Enum.map(StatusPages.get_status_page!(page.id).groups, & &1.name) == ["Web"]
    end

    test "publishes and edits the settings", %{conn: conn} do
      page = status_page_fixture(%{title: "Mine", slug: "mine"})

      {:ok, view, _html} = live(conn, ~p"/status-pages/#{page.id}")
      refute has_element?(view, "#view-public-page")
      view |> element("#toggle-published") |> render_click()
      assert has_element?(view, "#view-public-page[href='/status/mine']")
      assert StatusPages.get_status_page!(page.id).published

      view |> element("#edit-settings") |> render_click()
      assert_patch(view, ~p"/status-pages/#{page.id}/edit")

      assert view
             |> form("#status-page-form", status_page: %{title: ""})
             |> render_submit() =~ "can&#39;t be blank"

      view
      |> form("#status-page-form",
        status_page: %{title: "Ours", footer_text: "Hi", show_details: true}
      )
      |> render_submit()

      assert_patch(view, ~p"/status-pages/#{page.id}")

      assert %{title: "Ours", footer_text: "Hi", show_details: true} =
               StatusPages.get_status_page!(page.id)
    end

    test "deletes a page", %{conn: conn} do
      page = status_page_fixture(%{title: "Doomed"})
      {:ok, view, _html} = live(conn, ~p"/status-pages")
      view |> element("#delete-status-page-#{page.id}") |> render_click()
      refute has_element?(view, "#status-page-#{page.id}")
      assert StatusPages.get_status_page(page.id) == nil
    end

    test "redirects for unknown pages", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/status-pages"}}} = live(conn, ~p"/status-pages/0")
    end
  end

  defp group(page, group) do
    page.id
    |> StatusPages.get_status_page!()
    |> Map.fetch!(:groups)
    |> Enum.find(&(&1.id == group.id))
  end

  defp monitor_names(page, g), do: Enum.map(group(page, g).page_monitors, & &1.monitor.name)
end
