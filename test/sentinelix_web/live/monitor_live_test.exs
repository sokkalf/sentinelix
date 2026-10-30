defmodule SentinelixWeb.MonitorLiveTest do
  # Not async: creating monitors broadcasts on the global "monitors" topic,
  # which other (async) tests subscribe to.
  use SentinelixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Sentinelix.MonitoringFixtures
  import Sentinelix.NotificationsFixtures

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{Monitor, Settings}
  alias Sentinelix.Notifications
  alias SentinelixWeb.MonitorLive.Form

  setup :register_and_log_in_user

  describe "index" do
    test "shows an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/monitors")
      assert has_element?(view, "#monitors-empty")
      assert render(view) =~ "No monitors yet"
    end

    test "lists, searches, pauses and deletes monitors", %{conn: conn} do
      web = monitor_fixture(:http, %{name: "Web"})
      db = monitor_fixture(:tcp, %{name: "Database"})
      check_result_fixture(web, %{status: :up})

      {:ok, view, _html} = live(conn, ~p"/monitors")
      assert view |> element("#monitor-#{web.id}") |> render() =~ "Up"
      assert view |> element("#monitor-#{db.id}") |> render() =~ "db.example.com:5432"

      view |> form("#search-form", %{q: "data"}) |> render_change()
      refute has_element?(view, "#monitor-#{web.id}")
      assert has_element?(view, "#monitor-#{db.id}")
      view |> form("#search-form", %{q: ""}) |> render_change()

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
      monitor = monitor_fixture(:http, %{name: "Empty"})
      {:ok, view, html} = live(conn, ~p"/monitors/#{monitor}")

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

      {:ok, _view, html} =
        view
        |> form("#monitor-form",
          monitor: %{
            name: "Homepage",
            tags: "prod, web team",
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
      assert monitor.tags == ["prod", "web team"]
      assert monitor.interval_seconds == 30
      assert monitor.settings.method == "HEAD"
      assert monitor.settings.headers == %{"X-Token" => "abc", "Accept" => "text/html"}
      assert monitor.settings.accepted_status_codes == ["200-299", "301"]
    end

    test "renders type specific fields when the type changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/monitors/new")

      for {type, fields} <- [
            keyword: ~w(url keyword invert_keyword case_sensitive json_path),
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
      monitor = monitor_fixture(:tcp, %{name: "DB", tags: ["a", "b"]})
      {:ok, view, html} = live(conn, ~p"/monitors/#{monitor}/edit")
      assert html =~ "a, b"

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
  end
end
