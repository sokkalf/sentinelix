defmodule SentinelixWeb.MonitorLiveTest do
  # Not async: creating monitors broadcasts on the global "monitors" topic,
  # which other (async) tests subscribe to.
  use SentinelixWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Sentinelix.MaintenanceFixtures
  import Sentinelix.MonitoringFixtures
  import Sentinelix.NotificationsFixtures
  import Sentinelix.StatusPagesFixtures

  alias Sentinelix.{Maintenance, Monitoring, Notifications, Repo}
  alias Sentinelix.Monitoring.{Events, Monitor, Settings}
  alias Sentinelix.StatusPages.PageMonitor
  alias SentinelixWeb.MonitorLive.Form

  setup :register_and_log_in_user

  describe "index" do
    test "shows an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/monitors")
      assert has_element?(view, "#monitors-empty")
      assert render(view) =~ "No monitors yet"
    end

    test "lists, filters, pauses and deletes monitors", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"site" => "oslo"}})
      db = monitor_fixture(:tcp, %{name: "Database"})
      check_result_fixture(web, %{status: :up})

      {:ok, view, _html} = live(conn, ~p"/monitors")
      assert view |> element("#monitor-#{web.id}") |> render() =~ "Up"
      assert view |> element("#monitor-#{db.id}") |> render() =~ "db.example.com:5432"
      assert has_element?(view, "#monitor-#{web.id} [data-label='site=oslo']")

      view |> form("#filter-form", %{selector: "name~data"}) |> render_change()
      assert_patch(view, ~p"/monitors?#{[selector: "name~data"]}")
      refute has_element?(view, "#monitor-#{web.id}")
      assert has_element?(view, "#monitor-#{db.id}")

      view |> form("#filter-form", %{selector: "site=oslo"}) |> render_change()
      assert has_element?(view, "#monitor-#{web.id}")
      refute has_element?(view, "#monitor-#{db.id}")

      view |> form("#filter-form", %{selector: "status=pending, type=tcp"}) |> render_change()
      refute has_element?(view, "#monitor-#{web.id}")
      assert has_element?(view, "#monitor-#{db.id}")

      view |> form("#filter-form", %{selector: "status=nope"}) |> render_change()
      assert has_element?(view, "#selector-error", ~s(unknown status "nope"))
      assert has_element?(view, "#monitor-#{db.id}")

      {:ok, view, _html} = live(conn, ~p"/monitors?#{[selector: "site in ("]}")
      assert has_element?(view, "#selector-error", "expected a value at column 10")
      refute has_element?(view, "#monitor-#{web.id}")

      # Badges add a term.
      {:ok, view, _html} = live(conn, ~p"/monitors")
      view |> element("#monitor-#{web.id} a[data-label='site=oslo']") |> render_click()
      assert_patch(view, ~p"/monitors?#{[selector: "site=oslo"]}")
      refute has_element?(view, "#monitor-#{db.id}")
      assert has_element?(view, "#selector-suggestions option[value='site=oslo, type=http']")

      view |> element("#clear-filters") |> render_click()
      assert_patch(view, ~p"/monitors")
      assert has_element?(view, "#monitor-#{db.id}")

      view |> element("#toggle-#{web.id}") |> render_click()
      refute Monitoring.get_monitor!(web.id).enabled
      assert view |> element("#monitor-#{web.id}") |> render() =~ "Paused"

      view |> element("#toggle-#{web.id}") |> render_click()
      assert Monitoring.get_monitor!(web.id).enabled

      view |> element("#delete-#{db.id}") |> render_click()
      refute Monitoring.get_monitor(db.id)
      refute has_element?(view, "#monitor-#{db.id}")
      assert render(view) =~ "Database deleted"
    end

    test "links to cloning a monitor", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Web"})
      {:ok, view, _html} = live(conn, ~p"/monitors")

      {:ok, view, _html} =
        view
        |> element("#clone-#{monitor.id}")
        |> render_click()
        |> follow_redirect(conn, ~p"/monitors/#{monitor}/clone")

      assert has_element?(view, "#monitor_name[value='Web (copy)']")
    end

    test "applies bulk actions to the selected monitors", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"site" => "oslo", "env" => "dev"}})
      db = monitor_fixture(:tcp, %{name: "Database"})
      other = monitor_fixture(:http, %{name: "Other", labels: %{"site" => "oslo"}})
      channel = channel_fixture(:webhook, %{name: "Ops"})

      {:ok, view, _html} = live(conn, ~p"/monitors")
      refute has_element?(view, "#bulk-actions")

      view |> element("#select-#{web.id}") |> render_click()
      view |> element("#select-#{db.id}") |> render_click()
      assert has_element?(view, "#selection-count", "2 monitors selected")
      assert has_element?(view, "#select-#{web.id}[checked]")
      refute has_element?(view, "#select-#{other.id}[checked]")

      submit_bulk(view, "#bulk-labels-form", %{labels: "Env=prod, team=ops"}, "add")
      assert render(view) =~ "Added env=prod, team=ops to 2 monitors."

      assert Monitoring.get_monitor!(web.id).labels == %{
               "site" => "oslo",
               "env" => "prod",
               "team" => "ops"
             }

      assert Monitoring.get_monitor!(db.id).labels == %{"env" => "prod", "team" => "ops"}
      assert Monitoring.get_monitor!(other.id).labels == %{"site" => "oslo"}
      assert has_element?(view, "#monitor-#{db.id} [data-label='env=prod']")

      submit_bulk(view, "#bulk-labels-form", %{labels: "site team"}, "remove")
      assert render(view) =~ "Removed site, team from 2 monitors."
      assert Monitoring.get_monitor!(web.id).labels == %{"env" => "prod"}
      assert Monitoring.get_monitor!(other.id).labels == %{"site" => "oslo"}

      # Automatic labels can't be set or removed.
      submit_bulk(view, "#bulk-labels-form", %{labels: "host=web1"}, "add")
      assert render(view) =~ "host is an automatic label"
      submit_bulk(view, "#bulk-labels-form", %{labels: "type"}, "remove")
      assert render(view) =~ "type is an automatic label"
      assert Monitoring.get_monitor!(web.id).labels == %{"env" => "prod"}

      view |> element("#bulk-pause") |> render_click()
      assert render(view) =~ "2 monitors paused."
      refute Monitoring.get_monitor!(web.id).enabled
      refute Monitoring.get_monitor!(db.id).enabled
      assert Monitoring.get_monitor!(other.id).enabled
      assert view |> element("#monitor-#{db.id}") |> render() =~ "Paused"

      view |> element("#bulk-resume") |> render_click()
      assert Monitoring.get_monitor!(web.id).enabled
      assert Monitoring.get_monitor!(db.id).enabled

      submit_bulk(view, "#bulk-channels-form", %{channel_id: channel.id}, "attach")
      assert render(view) =~ "Attached Ops to 2 monitors."
      assert Enum.sort(Notifications.channel_monitor_ids(channel)) == Enum.sort([web.id, db.id])

      submit_bulk(view, "#bulk-channels-form", %{channel_id: channel.id}, "detach")
      assert render(view) =~ "Detached Ops from 2 monitors."
      assert Notifications.channel_monitor_ids(channel) == []

      # The selection survives the actions, until the monitors are deleted.
      assert has_element?(
               view,
               "#bulk-delete[data-confirm='Delete 2 monitors and all of their history?']"
             )

      view |> element("#bulk-delete") |> render_click()
      assert render(view) =~ "2 monitors deleted."
      refute Monitoring.get_monitor(web.id)
      refute Monitoring.get_monitor(db.id)
      assert Monitoring.get_monitor(other.id)
      refute has_element?(view, "#monitor-#{web.id}")
      refute has_element?(view, "#bulk-actions")
    end

    test "selects all monitors matching the selector", %{conn: conn} do
      web1 = monitor_fixture(:http, %{name: "Web 1"})
      web2 = monitor_fixture(:http, %{name: "Web 2"})
      db = monitor_fixture(:tcp, %{name: "Database"})

      {:ok, view, _html} = live(conn, ~p"/monitors")
      view |> form("#filter-form", %{selector: "name~web"}) |> render_change()
      view |> element("#select-all") |> render_click()
      assert has_element?(view, "#selection-count", "2 monitors selected")
      assert has_element?(view, "#select-all[checked]")
      assert has_element?(view, "#select-#{web1.id}[checked]")

      view |> element("#bulk-pause") |> render_click()
      refute Monitoring.get_monitor!(web1.id).enabled
      refute Monitoring.get_monitor!(web2.id).enabled
      assert Monitoring.get_monitor!(db.id).enabled

      # Widening the selector keeps the selection; "select all" then offers
      # every matching monitor.
      view |> form("#filter-form", %{selector: ""}) |> render_change()
      assert has_element?(view, "#selection-count", "2 monitors selected")
      refute has_element?(view, "#select-#{db.id}[checked]")
      view |> element("#select-all-matching", "Select all 3 monitors") |> render_click()
      assert has_element?(view, "#selection-count", "3 monitors selected")

      # Narrowing it deselects the monitors that no longer match.
      view |> form("#filter-form", %{selector: ~s(name~"web 2")}) |> render_change()
      assert has_element?(view, "#selection-count", "1 monitor selected")

      view |> element("#bulk-resume") |> render_click()
      assert Monitoring.get_monitor!(web2.id).enabled
      refute Monitoring.get_monitor!(web1.id).enabled

      view |> element("#select-all") |> render_click()
      refute has_element?(view, "#bulk-actions")
    end

    test "deselects monitors that stop matching the selector", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web"})
      {:ok, view, _html} = live(conn, ~p"/monitors")
      view |> form("#filter-form", %{selector: "name~web"}) |> render_change()
      view |> element("#select-#{web.id}") |> render_click()

      {:ok, _} = Monitoring.update_monitor(web, %{name: "Api"})
      refute has_element?(view, "#monitor-#{web.id}")
      refute has_element?(view, "#bulk-actions")
    end

    test "bulk label errors change nothing", %{conn: conn} do
      full = for i <- 1..64, into: %{}, do: {"k#{i}", ""}
      ok = monitor_fixture(:http, %{name: "Fine"})
      too_many = monitor_fixture(:http, %{name: "Full", labels: full})

      {:ok, view, _html} = live(conn, ~p"/monitors")
      view |> element("#select-all") |> render_click()

      submit_bulk(view, "#bulk-labels-form", %{labels: "env=prod"}, "add")
      assert render(view) =~ "Nothing changed, Full: at most 64 labels are allowed."
      assert Monitoring.get_monitor!(ok.id).labels == %{}
      assert Monitoring.get_monitor!(too_many.id).labels == full

      submit_bulk(view, "#bulk-labels-form", %{labels: "bad!key"}, "add")
      assert render(view) =~ ~s(Nothing changed: invalid label key &quot;bad!key&quot;.)

      submit_bulk(view, "#bulk-labels-form", %{labels: "k1=x"}, "remove")
      assert render(view) =~ "Remove labels by key (env, not env=prod)."
      assert Monitoring.get_monitor!(too_many.id).labels == full

      submit_bulk(view, "#bulk-labels-form", %{labels: " "}, "add")
      assert render(view) =~ "Enter labels such as env=prod"
    end

    test "updates on status changes", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Web"})
      {:ok, view, _html} = live(conn, ~p"/monitors")

      result = check_result_fixture(monitor, %{status: :down})
      Monitoring.broadcast_status_event(monitor, {:status_changed, monitor, :up, :down, result})
      assert view |> element("#monitor-#{monitor.id}") |> render() =~ "Down"
    end
  end

  describe "show" do
    test "renders a monitor without results", %{conn: conn} do
      monitor =
        monitor_fixture(:http, %{name: "Empty", labels: %{"env" => "prod", "legacy" => ""}})

      {:ok, view, html} = live(conn, ~p"/monitors/#{monitor}")
      assert has_element?(view, "[data-label='env=prod']", "env=prod")
      assert has_element?(view, "[data-label=legacy]", "legacy")
      refute has_element?(view, "[data-label=legacy][data-automatic]")
      # Automatic labels follow, marked as such.
      assert has_element?(view, "[data-automatic][data-label='type=http']")
      assert has_element?(view, "[data-automatic][data-label='host=example.com']")

      assert html =~ "Empty"
      assert html =~ "https://example.com/health"
      assert has_element?(view, "#no-checks")
      assert has_element?(view, "#chart-empty")
      assert has_element?(view, "#incidents-empty")
      assert has_element?(view, "#stat-uptime-24h", "–")
      assert has_element?(view, "#stat-uptime-90d", "–")
      assert has_element?(view, "#stat-p95-response", "–")
      assert has_element?(view, "#next-check", "Not running")
    end

    test "lists the channels that notify the monitor and why", %{conn: conn} do
      monitor = monitor_fixture(:http, %{labels: %{"env" => "prod"}})
      attached = channel_fixture(:webhook, %{name: "Attached"})
      both = channel_fixture(:webhook, %{name: "Both", selector: "env=prod"})
      off = channel_fixture(:webhook, %{name: "Off", selector: "env", enabled: false})
      other = channel_fixture(:webhook, %{name: "Other", selector: "env=dev"})
      :ok = Notifications.put_monitor_channels(monitor, [attached, both])

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")
      assert has_element?(view, "#monitor-channel-#{attached.id}", "attached")
      refute has_element?(view, "#monitor-channel-#{attached.id}", "via selector")
      assert has_element?(view, "#monitor-channel-#{both.id}", "attached")
      assert has_element?(view, "#monitor-channel-#{both.id}", "via selector env=prod")
      assert has_element?(view, "#monitor-channel-#{off.id}", "disabled")
      refute has_element?(view, "#monitor-channel-#{other.id}")

      # Channel changes show up live.
      {:ok, _} = Notifications.update_channel(other, %{selector: "env in (dev,prod)"})
      assert has_element?(view, "#monitor-channel-#{other.id}", "via selector")
    end

    test "sends a test notification to the routed channels", %{conn: conn} do
      capture_requests()
      monitor = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod"}})
      routed = channel_fixture(:webhook, %{name: "Routed", selector: "env=prod"})
      off = channel_fixture(:webhook, %{name: "Off", selector: "env=prod", enabled: false})

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")
      view |> element("#send-test-notification") |> render_click()

      assert render_async(view) =~ "Test notification sent to Routed."
      assert_received {:notification_request, %{body: %{"title" => title}}}
      assert title == "[TEST] Test notification for Web"
      refute_received {:notification_request, _}

      capture_requests(self(), 500)
      view |> element("#send-test-notification") |> render_click()
      assert render_async(view) =~ "Test notification failed for Routed: HTTP 500"

      # Only the disabled channel is left: nothing to test.
      {:ok, _} = Notifications.update_channel(routed, %{selector: ""})
      refute has_element?(view, "#monitor-channel-#{routed.id}")
      assert has_element?(view, "#send-test-notification[disabled]")
      {:ok, _} = Notifications.delete_channel(off)
      assert has_element?(view, "#no-channels")
    end

    test "shows the parent and the dependents", %{conn: conn} do
      host = monitor_fixture(:ping, %{name: "web1 ping"})
      monitor = monitor_fixture(:tcp, %{name: "web1 ssh", parent_id: host.id})
      child = monitor_fixture(:http, %{name: "Shop", parent_id: monitor.id})
      check_result_fixture(host, %{status: :down})
      check_result_fixture(child, %{status: :unreachable})

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")
      assert has_element?(view, "#parent a[href='/monitors/#{host.id}']", "web1 ping")
      assert has_element?(view, "#parent", "Down")
      assert has_element?(view, "#child-#{child.id}", "Shop")
      assert has_element?(view, "#child-#{child.id}", "Unreachable")
      refute has_element?(view, "#unreachable-notice")

      # An unreachable result says why.
      check_result = check_result_fixture(monitor, %{status: :unreachable, message: "refused"})
      send(view.pid, {:check_result, check_result})
      assert has_element?(view, "#monitor-status", "Unreachable")
      assert has_element?(view, "#unreachable-notice", "web1 ping is down")

      {:ok, view, _html} = live(conn, ~p"/monitors/#{host}")
      assert has_element?(view, "#parent", "Nothing")
      assert has_element?(view, "#child-#{monitor.id}", "web1 ssh")
      refute has_element?(view, "#child-#{child.id}")
    end

    test "renders results, stats and incidents and updates live", %{conn: conn} do
      monitor = monitor_fixture(:cert, %{name: "Cert"})
      check_result_fixture(monitor, %{status: :up, response_time_ms: 10, message: "valid"})
      incident_fixture(monitor, %{message: "handshake failed"})

      {:ok, view, html} = live(conn, ~p"/monitors/#{monitor}")
      assert html =~ "example.com:443"
      assert has_element?(view, "#stat-avg-response", "10 ms")
      assert has_element?(view, "#stat-uptime-24h", "100%")
      assert has_element?(view, "#stat-p95-response", "10 ms")
      assert has_element?(view, "#cert-info", "valid")
      assert has_element?(view, "#incidents", "handshake failed")
      assert has_element?(view, "#incidents", "Ongoing")
      refute has_element?(view, "#chart-empty")

      check_result_fixture(monitor, %{status: :down, response_time_ms: 30, message: "expired"})
      assert has_element?(view, "#latest-message", "expired")
      assert has_element?(view, "#monitor-status", "Down")
      assert has_element?(view, "#stat-avg-response", "10 ms")
      assert has_element?(view, "#stat-uptime-24h", "50.00%")
      assert has_element?(view, "#stat-uptime-7d", "50.00%")
      assert has_element?(view, "#stat-uptime-30d", "50.00%")
      assert has_element?(view, "#stat-uptime-90d", "50.00%")
      assert has_element?(view, "#heartbeats [data-status=down]")

      incident = Monitoring.get_open_incident(monitor)
      {:ok, _} = Monitoring.resolve_incident(incident)
      assert has_element?(view, "#incidents", "Resolved")

      new_incident = incident_fixture(monitor, %{message: "down again"})
      assert has_element?(view, "#incidents-#{new_incident.id}", "down again")
    end

    test "events show in the timeline, with their details, and live", %{conn: conn} do
      monitor = monitor_fixture(:postgres, %{name: "DB"})
      incident = incident_fixture(monitor, %{message: "refused"})

      {:ok, _event, _status} =
        Events.record_event(monitor, %{
          "title" => "Patroni on_role_change: db1 is now primary",
          "role" => "primary",
          "attempt" => 2
        })

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")
      [event] = Events.list_events(monitor)

      assert has_element?(view, "#incidents-#{incident.id}[data-kind=incident]", "refused")
      row = "#incidents-event-#{event.id}[data-kind=event][data-severity=info]"
      assert has_element?(view, row, "Patroni on_role_change: db1 is now primary")
      assert has_element?(view, "#{row} dt", "role")
      assert has_element?(view, "#{row} dd", "primary")
      assert has_element?(view, "#{row} dd", "2")

      # Newest first.
      assert view |> element("#incidents") |> render() |> :binary.match("Patroni") <
               view |> element("#incidents") |> render() |> :binary.match("refused")

      {:ok, live_event, _} =
        Events.record_event(monitor, %{"title" => "Disk 91% full", "severity" => "warning"})

      assert has_element?(view, "#incidents-event-#{live_event.id}[data-severity=warning]")
    end

    test "shows active warnings and clears them", %{conn: conn, user: user} do
      monitor = monitor_fixture(:postgres)

      for {key, title} <- [{"disk", "Disk 91% full"}, {"", "Replication lag"}] do
        {:ok, _, _} =
          Events.record_event(monitor, %{
            "title" => title,
            "severity" => "warning",
            "key" => key,
            "ttl" => "1h"
          })
      end

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")
      [disk, lag] = Events.active_warnings(monitor)
      assert has_element?(view, "#warning-#{disk.id}", "Disk 91% full")
      assert has_element?(view, "#warning-#{disk.id} code", "disk")
      assert has_element?(view, "#warning-#{disk.id}-expires")
      assert has_element?(view, "#warning-#{lag.id}", "Replication lag")

      view |> element("#clear-warning-#{lag.id}") |> render_click()
      assert render(view) =~ "Warning cleared."
      refute has_element?(view, "#warning-#{lag.id}")
      assert has_element?(view, "#warning-#{disk.id}")
      refute has_element?(view, "#clear-warnings")

      assert [%{title: "Warning cleared: Replication lag", metadata: metadata} | _] =
               Events.list_events(monitor)

      assert metadata == %{"cleared_by" => user.email}

      # Live: a new warning shows up.
      {:ok, _, _} =
        Events.record_event(monitor, %{
          "title" => "Backup late",
          "severity" => "warning",
          "key" => "backup"
        })

      assert has_element?(view, "#active-warnings", "Backup late")

      view |> element("#clear-warnings") |> render_click()
      assert render(view) =~ "2 warnings cleared."
      refute has_element?(view, "#active-warnings")
    end

    test "generates, regenerates and revokes the event token", %{conn: conn} do
      monitor = monitor_fixture(:http)
      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")

      refute has_element?(view, "#event-url-value")
      view |> element("#generate-event-token") |> render_click()
      %{event_token: token} = Monitoring.get_monitor!(monitor.id)
      assert is_binary(token)

      assert view |> element("#event-url-value") |> render() =~ "/api/v1/events/#{token}"
      assert view |> element("#event-curl") |> render() =~ "/api/v1/events/#{token}"

      view |> element("#regenerate-event-token") |> render_click()
      %{event_token: new_token} = Monitoring.get_monitor!(monitor.id)
      assert new_token != token
      assert view |> element("#event-url-value") |> render() =~ new_token

      view |> element("#revoke-event-token") |> render_click()
      assert Monitoring.get_monitor!(monitor.id).event_token == nil
      assert has_element?(view, "#generate-event-token")
    end

    test "the warning status", %{conn: conn} do
      monitor = monitor_fixture()
      check_result_fixture(monitor, %{status: :warning, message: "Warning: Disk 91% full"})
      incident_fixture(monitor, %{to_status: :warning, message: "Warning: Disk 91% full"})

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")
      assert has_element?(view, "#monitor-status", "Warning")
      assert has_element?(view, "#heartbeats [data-status=warning]")
      assert has_element?(view, "#incidents [data-kind=incident]", "Warning")
      assert has_element?(view, "#stat-uptime-24h", "100%")
    end

    test "switches the chart range", %{conn: conn} do
      monitor = monitor_fixture()
      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")

      assert has_element?(view, "#response-chart[data-range-ms='86400000'][data-live=true]")
      view |> element("#range-7d") |> render_click()
      assert_patch(view, ~p"/monitors/#{monitor}?range=7d")
      assert has_element?(view, "#response-chart[data-range-ms='604800000'][data-live=false]")

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}?range=bogus")
      assert has_element?(view, "#range-24h.btn-active")
    end

    test "long ranges chart hourly statistics", %{conn: conn} do
      monitor = monitor_fixture()
      hour = DateTime.utc_now() |> DateTime.add(-2, :day) |> Sentinelix.Stats.floor_hour()

      for {offset, status, ms} <- [{0, :up, 100}, {60, :up, 300}, {120, :down, nil}] do
        check_result_fixture(monitor, %{
          status: status,
          response_time_ms: ms,
          checked_at: DateTime.add(hour, offset, :second)
        })
      end

      # Maintenance-only hours are left out.
      check_result_fixture(monitor, %{
        status: :maintenance,
        checked_at: DateTime.add(hour, -3600, :second)
      })

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}?range=24h")
      assert has_element?(view, "#chart-empty")

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}?range=7d")
      refute has_element?(view, "#chart-empty")

      [points] =
        view
        |> element("#response-chart")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("data-points")

      # Average of the up checks; marked down.
      assert Jason.decode!(points) == [[DateTime.to_unix(hour, :millisecond), 200, 1]]
    end

    test "pauses, resumes and checks now", %{conn: conn} do
      monitor = monitor_fixture()
      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")

      view |> element("#toggle-monitor") |> render_click()
      refute Monitoring.get_monitor!(monitor.id).enabled
      assert has_element?(view, "#monitor-status", "Paused")
      assert has_element?(view, "#next-check", "Paused")
      assert has_element?(view, "#check-now[disabled]")

      view |> element("#toggle-monitor") |> render_click()
      assert Monitoring.get_monitor!(monitor.id).enabled

      # The engine isn't running in tests.
      assert view |> element("#check-now") |> render_click() =~ "isn&#39;t running"
    end

    test "deletes the monitor", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Doomed"})
      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")

      {:ok, _view, html} =
        view
        |> element("#delete-monitor")
        |> render_click()
        |> follow_redirect(conn, ~p"/monitors")

      assert html =~ "Doomed deleted."

      refute Monitoring.get_monitor(monitor.id)
    end

    test "leaves when the monitor is deleted elsewhere", %{conn: conn} do
      monitor = monitor_fixture()
      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")
      {:ok, _} = Monitoring.delete_monitor(monitor)
      assert_redirect(view, ~p"/monitors")
    end

    test "shows the push URL of push monitors", %{conn: conn} do
      monitor = monitor_fixture(:push)
      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")

      assert view |> element("#push-url-value") |> render() =~
               "/api/push/#{monitor.settings.push_token}"

      assert has_element?(view, "#push-curl", "curl")
      refute has_element?(view, "#check-now")
    end

    test "clones the monitor", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "Web"})
      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}")

      {:ok, view, _html} =
        view
        |> element("#clone-monitor")
        |> render_click()
        |> follow_redirect(conn, ~p"/monitors/#{monitor}/clone")

      assert has_element?(view, "#monitor_name[value='Web (copy)']")
    end

    test "redirects for unknown monitors", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/monitors"}}} = live(conn, ~p"/monitors/0")
      assert {:error, {:live_redirect, %{to: "/monitors"}}} = live(conn, "/monitors/nope")
    end
  end

  describe "form" do
    test "creates an http monitor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/monitors/new")
      assert has_element?(view, "#settings-fields[data-type=http]")
      assert has_element?(view, "#monitor_settings_0_url, #monitor_settings_url")

      assert view
             |> form("#monitor-form", monitor: %{name: "", settings: %{url: "nope"}})
             |> render_change() =~ "must be a valid http:// or https:// URL"

      view |> element("#add-label") |> render_click()
      view |> element("#add-label") |> render_click()
      view |> element("#add-label") |> render_click()

      {:ok, _view, html} =
        view
        |> form("#monitor-form",
          monitor: %{
            name: "Homepage",
            labels: %{
              "0" => %{key: " Env ", value: "prod"},
              "1" => %{key: "", value: ""},
              "2" => %{key: "web", value: ""}
            },
            interval_seconds: "30",
            settings: %{
              url: "https://example.com",
              method: "HEAD",
              headers: "X-Token: abc\nAccept: text/html",
              accepted_status_codes: "200-299, 301"
            }
          }
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Monitor created"
      assert [monitor] = Monitoring.list_monitors()
      assert monitor.name == "Homepage"
      assert monitor.labels == %{"env" => "prod", "web" => ""}
      assert monitor.interval_seconds == 30
      assert monitor.settings.method == "HEAD"
      assert monitor.settings.headers == %{"X-Token" => "abc", "Accept" => "text/html"}
      assert monitor.settings.accepted_status_codes == ["200-299", "301"]
    end

    test "renders type specific fields when the type changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/monitors/new")

      for {type, fields} <- [
            tcp: ~w(host port),
            ping: ~w(host),
            dns: ~w(host dns_record_type dns_resolver expected_value),
            cert: ~w(host port cert_warn_days cert_critical_days),
            push: ~w(push_token push_grace_seconds),
            postgres:
              ~w(host port database username ssl_mode query expected_value comparison expected_rows rows_comparison replication_check),
            http: ~w(url method headers body accepted_status_codes follow_redirects)
          ] do
        view |> form("#monitor-form", monitor: %{type: type}) |> render_change()
        assert has_element?(view, "#settings-fields[data-type=#{type}]")

        for field <- fields do
          assert has_element?(view, "[name='monitor[settings][#{field}]']"),
                 "expected #{field} for #{type}"
        end
      end

      view |> form("#monitor-form", monitor: %{type: :tcp}) |> render_change()
      refute has_element?(view, "[name='monitor[settings][url]']")
    end

    test "creates a postgres monitor with a write-only password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/monitors/new")
      view |> form("#monitor-form", monitor: %{type: :postgres}) |> render_change()

      assert has_element?(view, "#settings-group-connection [name='monitor[secrets][password]']")
      assert has_element?(view, "#settings-group-query [name='monitor[settings][query]']")

      assert has_element?(
               view,
               "#settings-group-replication [name='monitor[settings][replication_check]']"
             )

      # Fields that depend on other fields.
      refute has_element?(view, "[name='monitor[settings][ssl_ca_cert]']")
      refute has_element?(view, "[name='monitor[settings][min_standbys]']")
      refute has_element?(view, "[name='monitor[settings][lag_warn_seconds]']")

      view
      |> form("#monitor-form",
        monitor: %{
          secrets: %{password: "typed-pw"},
          settings: %{ssl_mode: "verify-full", replication_check: "primary"}
        }
      )
      |> render_change()

      assert has_element?(view, "[name='monitor[settings][ssl_ca_cert]']")
      assert has_element?(view, "[name='monitor[settings][min_standbys]']")
      assert has_element?(view, "[name='monitor[settings][lag_critical_bytes]']")
      # What was typed survives the re-render.
      assert has_element?(view, "[name='monitor[secrets][password]'][value='typed-pw']")
      refute has_element?(view, "[name='monitor[secrets][clear_password]']")

      {:ok, _view, html} =
        view
        |> form("#monitor-form",
          monitor: %{
            name: "Main DB",
            secrets: %{password: "s3cret-pw"},
            settings: %{
              host: "db.example.com",
              database: "app",
              username: "sentinelix_monitor",
              ssl_mode: "require",
              replication_check: "primary",
              min_standbys: "2",
              lag_warn_seconds: "30"
            }
          }
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "db.example.com:5432/app"
      refute html =~ "s3cret-pw"

      assert [monitor] = Monitoring.list_monitors()
      assert monitor.secrets == %{"password" => "s3cret-pw"}

      assert %{database: "app", replication_check: "primary", min_standbys: 2} =
               monitor.settings
    end

    test "the settings groups contain every field of the type" do
      for type <- Monitor.types() do
        grouped =
          type |> Form.settings_groups() |> Enum.flat_map(&elem(&1, 1))

        secrets =
          type |> Monitor.secret_fields() |> Enum.map(&String.to_atom/1)

        assert Enum.sort(grouped) ==
                 Enum.sort(Settings.fields_for(type) ++ secrets)
      end
    end

    test "never renders a stored password and keeps it when left blank", %{conn: conn} do
      monitor = monitor_fixture(:postgres, %{secrets: %{password: "stored-s3cret"}})

      {:ok, view, html} = live(conn, ~p"/monitors/#{monitor}/edit")
      refute html =~ "stored-s3cret"
      assert has_element?(view, "[name='monitor[secrets][password]'][placeholder*=unchanged]")

      refute view
             |> form("#monitor-form", monitor: %{name: "Renamed", settings: %{port: "70000"}})
             |> render_submit() =~ "stored-s3cret"

      {:ok, _view, html} =
        view
        |> form("#monitor-form", monitor: %{name: "Renamed", settings: %{port: "5433"}})
        |> render_submit()
        |> follow_redirect(conn, ~p"/monitors/#{monitor}")

      refute html =~ "stored-s3cret"
      assert Monitoring.get_monitor!(monitor.id).secrets == %{"password" => "stored-s3cret"}

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}/edit")

      {:ok, _view, _html} =
        view
        |> form("#monitor-form", monitor: %{secrets: %{clear_password: "true"}})
        |> render_submit()
        |> follow_redirect(conn, ~p"/monitors/#{monitor}")

      assert Monitoring.get_monitor!(monitor.id).secrets == %{}
    end

    test "creates a push monitor and shows its push URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/monitors/new")
      view |> form("#monitor-form", monitor: %{type: :push}) |> render_change()

      token = view |> element("[name='monitor[settings][push_token]']") |> render()
      [_, token] = Regex.run(~r/value="([^"]+)"/, token)
      assert has_element?(view, "#push-url-preview", "/api/push/#{token}")

      view |> element("#regenerate-token") |> render_click()
      refute has_element?(view, "#push-url-preview", "/api/push/#{token}")

      {:ok, _view, _html} =
        view
        |> form("#monitor-form", monitor: %{name: "Cron job"})
        |> render_submit()
        |> follow_redirect(conn)

      assert [%{type: :push, settings: %{push_token: saved}}] = Monitoring.list_monitors()
      assert saved != token
    end

    test "edits a monitor", %{conn: conn} do
      monitor = monitor_fixture(:tcp, %{name: "DB", labels: %{"env" => "prod"}})
      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}/edit")
      assert has_element?(view, "#monitor_labels_0_key[value=env]")
      assert has_element?(view, "#monitor_labels_0_value[value=prod]")

      assert view
             |> form("#monitor-form", monitor: %{settings: %{port: "70000"}})
             |> render_submit() =~ "must be less than or equal to 65535"

      {:ok, _view, html} =
        view
        |> form("#monitor-form", monitor: %{name: "Postgres", settings: %{port: "5433"}})
        |> render_submit()
        |> follow_redirect(conn, ~p"/monitors/#{monitor}")

      assert html =~ "Monitor updated"
      assert %{name: "Postgres", settings: %{port: 5433}} = Monitoring.get_monitor!(monitor.id)
    end

    test "redirects for unknown monitors", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/monitors"}}} = live(conn, ~p"/monitors/0/edit")
      assert {:error, {:live_redirect, %{to: "/monitors"}}} = live(conn, ~p"/monitors/0/clone")
    end

    test "clones a monitor with its labels and notification channels", %{conn: conn} do
      reset_maintenance_cache()
      channel = channel_fixture(:slack, %{name: "Ops"})
      default = channel_fixture(:webhook, %{name: "Default hook", default: true})

      source =
        monitor_fixture(:tcp, %{
          name: "db1",
          interval_seconds: 120,
          max_retries: 3,
          labels: %{"instance" => "db1", "service" => "billing"},
          settings: %{host: "db1.example.com", port: 5432}
        })

      :ok = Notifications.put_monitor_channels(source, [channel])
      window = window_fixture(%{monitor_ids: [source.id]})
      _page = published_page_fixture([source])

      {:ok, view, html} = live(conn, ~p"/monitors/#{source}/clone")
      assert html =~ "Clone monitor"
      assert html =~ "Maintenance windows and status pages are not copied"
      assert has_element?(view, "#monitor_name[value='db1 (copy)']")
      assert has_element?(view, "#settings-fields[data-type=tcp]")
      assert has_element?(view, "[name='monitor[settings][host]'][value='db1.example.com']")
      assert has_element?(view, "#monitor_interval_seconds[value='120']")
      assert has_element?(view, "#monitor_labels_0_key[value=instance]")
      assert has_element?(view, "#monitor_labels_0_value[value=db1]")
      assert has_element?(view, "#automatic-labels [data-label='host=db1.example.com']")
      # The source's channels, not the defaults.
      assert has_element?(view, "#channel-#{channel.id}[checked]")
      refute has_element?(view, "#channel-#{default.id}[checked]")

      {:ok, _view, html} =
        view
        |> form("#monitor-form",
          monitor: %{
            name: "db2",
            settings: %{host: "db2.example.com"},
            labels: %{"0" => %{key: "instance", value: "db2"}, "1" => %{key: "service"}}
          }
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Monitor created"

      clone = Enum.find(Monitoring.list_monitors(), &(&1.name == "db2"))
      assert clone.id != source.id

      assert %{
               type: :tcp,
               interval_seconds: 120,
               max_retries: 3,
               labels: %{"instance" => "db2", "service" => "billing"},
               settings: %{host: "db2.example.com", port: 5432}
             } = clone

      assert Notifications.monitor_channel_ids(clone) == [channel.id]
      assert Enum.map(Maintenance.get_window!(window.id).monitors, & &1.id) == [source.id]
      assert Repo.all(from pm in PageMonitor, select: pm.monitor_id) == [source.id]

      # The source is unchanged.
      assert %{name: "db1", settings: %{host: "db1.example.com"}} =
               Monitoring.get_monitor!(source.id)
    end

    test "a cloned postgres monitor needs its password entered again", %{conn: conn} do
      source =
        monitor_fixture(:postgres, %{name: "DB", secrets: %{password: "source-s3cret"}})

      {:ok, view, html} = live(conn, ~p"/monitors/#{source}/clone")
      refute html =~ "source-s3cret"
      refute has_element?(view, "[name='monitor[secrets][password]'][placeholder*=unchanged]")
      refute has_element?(view, "[name='monitor[secrets][clear_password]']")
      assert has_element?(view, "#monitor_secrets_reenter_password", "enter the password again")

      # A blank password doesn't keep the source's.
      html =
        view
        |> form("#monitor-form", monitor: %{secrets: %{password: ""}})
        |> render_submit()

      refute html =~ "source-s3cret"
      assert has_element?(view, "#settings-group-connection", "can't be blank")
      assert [_source] = Monitoring.list_monitors()

      {:ok, _view, html} =
        view
        |> form("#monitor-form", monitor: %{secrets: %{password: "clone-s3cret"}})
        |> render_submit()
        |> follow_redirect(conn)

      refute html =~ "s3cret"

      clone = Enum.find(Monitoring.list_monitors(), &(&1.id != source.id))
      assert clone.name == "DB (copy)"
      assert clone.secrets == %{"password" => "clone-s3cret"}
      assert Monitoring.get_monitor!(source.id).secrets == %{"password" => "source-s3cret"}
    end

    test "a cloned push monitor gets a new push token", %{conn: conn} do
      source = monitor_fixture(:push)

      {:ok, view, html} = live(conn, ~p"/monitors/#{source}/clone")
      refute html =~ source.settings.push_token

      {:ok, _view, _html} =
        view
        |> form("#monitor-form")
        |> render_submit()
        |> follow_redirect(conn)

      clone = Enum.find(Monitoring.list_monitors(), &(&1.id != source.id))
      assert clone.type == :push
      assert clone.settings.push_token != source.settings.push_token
    end

    test "suggests the ping monitor of the host as the parent", %{conn: conn} do
      ping = monitor_fixture(:ping, %{name: "web1 ping", settings: %{host: "web1.example.com"}})
      _other = monitor_fixture(:ping, %{name: "web2 ping", settings: %{host: "web2.example.com"}})

      {:ok, view, _html} = live(conn, ~p"/monitors/new")
      refute has_element?(view, "#suggested-parent")
      assert has_element?(view, "#monitor_parent_id option[value='#{ping.id}']", "web1 ping")

      view
      |> form("#monitor-form",
        monitor: %{name: "Shop", settings: %{url: "https://web1.example.com/shop"}}
      )
      |> render_change()

      assert has_element?(view, "#suggested-parent", "web1 ping")
      view |> element("#use-suggested-parent") |> render_click()
      refute has_element?(view, "#suggested-parent")
      assert has_element?(view, "#monitor_parent_id option[value='#{ping.id}'][selected]")

      {:ok, _view, _html} =
        view
        |> form("#monitor-form")
        |> render_submit()
        |> follow_redirect(conn)

      assert %{parent_id: parent_id} = Repo.get_by!(Monitor, name: "Shop")
      assert parent_id == ping.id
    end

    test "can't depend on itself or a dependent, cycles are rejected", %{conn: conn} do
      a = monitor_fixture(:ping, %{name: "a"})
      b = monitor_fixture(:tcp, %{name: "b", parent_id: a.id})
      c = monitor_fixture(:http, %{name: "c"})

      {:ok, view, _html} = live(conn, ~p"/monitors/#{a}/edit")
      refute has_element?(view, "#monitor_parent_id option[value='#{a.id}']")
      refute has_element?(view, "#monitor_parent_id option[value='#{b.id}']")
      assert has_element?(view, "#monitor_parent_id option[value='#{c.id}']")

      # Submitted anyway (e.g. b became a dependent after the form was opened).
      {:ok, _} = Monitoring.update_monitor(c, %{parent_id: a.id})

      assert view
             |> form("#monitor-form")
             |> render_submit(%{monitor: %{parent_id: c.id}}) =~ "would create a dependency cycle"

      assert Monitoring.get_monitor!(a.id).parent_id == nil
    end

    test "shows the automatic labels and rejects their keys", %{conn: conn} do
      monitor = monitor_fixture(:tcp, %{settings: %{host: "db.example.com", port: 5432}})

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}/edit")
      assert has_element?(view, "#automatic-labels [data-label='type=tcp']")
      assert has_element?(view, "#automatic-labels [data-label='host=db.example.com']")

      # They follow the settings as they are edited.
      view
      |> form("#monitor-form", monitor: %{settings: %{host: "DB2.example.com."}})
      |> render_change()

      assert has_element?(view, "#automatic-labels [data-label='host=db2.example.com']")

      view |> element("#add-label") |> render_click()

      html =
        view
        |> form("#monitor-form", monitor: %{labels: %{"0" => %{key: "host", value: "db1"}}})
        |> render_submit()

      assert html =~ "host is an automatic label, use another key"
      assert Monitoring.get_monitor!(monitor.id).labels == %{}
    end

    test "edits labels with autocompletion of keys and values", %{conn: conn} do
      monitor_fixture(:http, %{labels: %{"site" => "oslo", "env" => "prod"}})
      monitor_fixture(:http, %{labels: %{"site" => "helsinki"}})
      monitor = monitor_fixture(:tcp, %{labels: %{"site" => "oslo", "legacy" => ""}})

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}/edit")
      # Rows sorted by key.
      assert has_element?(view, "#monitor_labels_0_key[value=legacy]")
      assert has_element?(view, "#monitor_labels_1_key[value=site]")
      assert has_element?(view, "#label-keys option[value=env]")
      assert has_element?(view, "#label-keys option[value=site]")
      assert has_element?(view, "#label-values-1 option[value=helsinki]")
      assert has_element?(view, "#label-values-1 option[value=oslo]")

      # Duplicate keys and invalid keys are errors.
      view |> element("#add-label") |> render_click()

      html =
        view
        |> form("#monitor-form", monitor: %{labels: %{"2" => %{key: "Site", value: "bergen"}}})
        |> render_change()

      assert html =~ "duplicate label key site"
      # The values of the key typed so far are suggested.
      assert has_element?(view, "#label-values-2 option[value=oslo]")

      html =
        view
        |> form("#monitor-form", monitor: %{labels: %{"2" => %{key: "bad key", value: ""}}})
        |> render_submit()

      assert html =~ ~s(invalid label key &quot;bad key&quot;)

      # Removing rows keeps the others.
      view |> element("#remove-label-2") |> render_click()
      view |> element("#remove-label-0") |> render_click()
      refute has_element?(view, "#label-row-1")
      assert has_element?(view, "#monitor_labels_0_key[value=site]")

      view |> form("#monitor-form") |> render_submit()
      assert Monitoring.get_monitor!(monitor.id).labels == %{"site" => "oslo"}

      # Removing every label clears them.
      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}/edit")
      view |> element("#remove-label-0") |> render_click()
      view |> form("#monitor-form") |> render_submit()
      assert Monitoring.get_monitor!(monitor.id).labels == %{}
    end

    test "selects notification channels", %{conn: conn} do
      default = channel_fixture(:webhook, %{name: "Default hook", default: true})
      other = channel_fixture(:slack, %{name: "Slack"})

      {:ok, view, _html} = live(conn, ~p"/monitors/new")
      assert has_element?(view, "#channel-#{default.id}[checked]")
      refute has_element?(view, "#channel-#{other.id}[checked]")

      {:ok, _view, _html} =
        view
        |> form("#monitor-form",
          monitor: %{name: "Notified", settings: %{url: "https://example.com"}},
          channel_ids: ["", to_string(other.id)]
        )
        |> render_submit()
        |> follow_redirect(conn)

      [monitor] = Monitoring.list_monitors()
      assert Notifications.monitor_channel_ids(monitor) == [other.id]

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}/edit")
      assert has_element?(view, "#channel-#{other.id}[checked]")

      {:ok, _view, _html} =
        view
        |> form("#monitor-form", channel_ids: [""])
        |> render_submit()
        |> follow_redirect(conn)

      assert Notifications.monitor_channel_ids(monitor) == []
    end

    test "marks the channels the labels being edited route to", %{conn: conn} do
      monitor = monitor_fixture(:http, %{labels: %{"env" => "dev"}})
      prod = channel_fixture(:webhook, %{name: "Prod", selector: "env=prod"})
      http = channel_fixture(:webhook, %{name: "HTTP", selector: "type=http"})
      plain = channel_fixture(:webhook, %{name: "Plain"})

      {:ok, view, _html} = live(conn, ~p"/monitors/#{monitor}/edit")
      refute has_element?(view, "#channel-#{prod.id}-routed")
      assert has_element?(view, "#channel-#{http.id}-routed", "type=http")
      refute has_element?(view, "#channel-#{plain.id}-routed")

      # Unsaved labels count, before the stored all_labels would.
      view
      |> form("#monitor-form", monitor: %{labels: %{"0" => %{key: "env", value: "prod"}}})
      |> render_change()

      assert has_element?(view, "#channel-#{prod.id}-routed", "env=prod")
      # Routing doesn't check the box: that's an attachment.
      refute has_element?(view, "#channel-#{prod.id}[checked]")
    end
  end

  # Submits a bulk action form with the button of the given `op`.
  defp submit_bulk(view, selector, data, op) do
    view
    |> form(selector, data)
    |> put_submitter("button[name=op][value=#{op}]")
    |> render_submit()
  end
end
