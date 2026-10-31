defmodule SentinelixWeb.MonitorImportTest do
  # Not async: importing broadcasts on the global "monitors" topic.
  use SentinelixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Monitor

  setup :register_and_log_in_user

  describe "export download" do
    test "downloads all monitors or those matching the selector", %{conn: conn} do
      monitor_fixture(:ping, %{name: "Router", labels: %{"env" => "prod"}})
      db = monitor_fixture(:postgres, %{name: "Database", secrets: %{"password" => "pw-i49"}})

      conn = get(conn, ~p"/monitors/export")
      assert get_resp_header(conn, "content-type") == ["application/yaml; charset=utf-8"]
      assert get_resp_header(conn, "content-disposition") |> hd() =~ "sentinelix-monitors.yaml"
      body = response(conn, 200)
      assert body =~ "name: Router"
      assert body =~ "name: Database"
      refute body =~ "pw-i49"
      assert Monitor.secret(db, "password") == "pw-i49"

      body = conn |> recycle() |> get(~p"/monitors/export?selector=env=prod") |> response(200)
      assert body =~ "name: Router"
      refute body =~ "name: Database"
    end

    test "redirects on an invalid selector", %{conn: conn} do
      conn = get(conn, ~p"/monitors/export?selector=status=down")
      assert redirected_to(conn) == ~p"/monitors"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid selector"
    end

    test "the monitor list links to the export of its selector without status terms",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/monitors?selector=env=prod, status=down")

      assert view |> element("#export-monitors") |> render() =~
               ~s(href="/monitors/export?selector=env%3Dprod")

      assert has_element?(view, ~s(#import-monitors[href="/monitors/import"]))
    end
  end

  describe "import" do
    defp upload(view, name, content) do
      file =
        file_input(view, "#import-form", :file, [
          %{name: name, content: content, type: "application/yaml"}
        ])

      render_upload(file, name)
    end

    test "checks the file, shows the changes and imports them", %{conn: conn} do
      router = monitor_fixture(:ping, %{name: "Router", settings: %{host: "10.0.0.1"}})
      monitor_fixture(:ping, %{name: "Leftover"})

      {:ok, view, _html} = live(conn, ~p"/monitors/import")

      upload(view, "monitors.yaml", """
      version: 1
      monitors:
        - {name: Router, type: ping, interval_seconds: 300, settings: {host: 10.0.0.1}}
        - {name: Edge, type: ping, parent: Router, settings: {host: 10.0.0.2}}
      """)

      view |> form("#import-form", %{"report_missing" => "true"}) |> render_submit()

      assert view |> element("#count-create") |> render() =~ "1 to create"
      assert view |> element("#count-update") |> render() =~ "1 to update"
      assert render(view) =~ "interval_seconds"
      assert view |> element("#import-missing") |> render() =~ "Leftover"
      # A dry run so far.
      assert Monitoring.get_monitor!(router.id).interval_seconds == 60

      assert {:error, {:live_redirect, %{to: "/monitors", flash: _flash}}} =
               view |> element("#apply-import") |> render_click()

      assert Monitoring.get_monitor!(router.id).interval_seconds == 300
      assert [edge] = Monitoring.list_monitors(selector: "name=Edge")
      assert edge.parent_id == router.id
    end

    test "shows every error and imports nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/monitors/import")

      upload(view, "broken.yaml", """
      version: 1
      monitors:
        - {name: A, type: ping}
        - {name: B, type: nope}
      """)

      view |> form("#import-form") |> render_submit()

      errors = view |> element("#import-errors") |> render()
      assert errors =~ "broken.yaml"
      assert errors =~ "monitor 1 &quot;A&quot;: settings.host can&#39;t be blank"
      assert errors =~ "monitor 2 &quot;B&quot;: type must be one of"
      refute has_element?(view, "#apply-import")
      assert Monitoring.list_monitors() == []
    end

    test "an up-to-date file has nothing to import", %{conn: conn} do
      monitor_fixture(:ping, %{name: "Router", settings: %{host: "10.0.0.1"}})
      {:ok, yaml} = Monitoring.Export.export()

      {:ok, view, _html} = live(conn, ~p"/monitors/import")
      upload(view, "monitors.yml", yaml)
      view |> form("#import-form") |> render_submit()

      assert render(view) =~ "Every monitor in the file is up to date."
      refute has_element?(view, "#apply-import")

      view |> element("#reset-import") |> render_click()
      assert has_element?(view, "#import-form")
    end
  end
end
