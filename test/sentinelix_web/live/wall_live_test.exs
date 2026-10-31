defmodule SentinelixWeb.WallLiveTest do
  # Not async: creating monitors broadcasts on the global "monitors" topic,
  # maintenance windows are cached globally, and one test raises the
  # global log level.
  use SentinelixWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Sentinelix.AccountsFixtures
  import Sentinelix.DisplayTokensFixtures
  import Sentinelix.MaintenanceFixtures
  import Sentinelix.MonitoringFixtures
  import Sentinelix.SavedViewsFixtures

  alias Sentinelix.{Accounts, DisplayTokens, Monitoring, RateLimit, Repo, SavedViews}
  alias Sentinelix.Accounts.Scope
  alias Sentinelix.DisplayTokens.DisplayToken

  setup :reset_maintenance_cache

  setup do
    user = oidc_user_fixture(%{groups: ["ops"]})
    %{user: user, scope: Scope.for_user(user)}
  end

  defp wall_path(token), do: ~p"/wall/#{token}"

  defp tile_text(view, monitor),
    do:
      view
      |> element("#tile-#{monitor.id}")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()

  describe "the display" do
    test "shows the monitors of the view, large, with nothing to click", %{
      conn: conn,
      scope: scope
    } do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod"}})
      db = monitor_fixture(:tcp, %{name: "Database", labels: %{"env" => "prod"}})
      _other = monitor_fixture(:http, %{name: "Staging", labels: %{"env" => "staging"}})
      check_result_fixture(web, %{status: :up, response_time_ms: 42})
      check_result_fixture(db, %{status: :down, response_time_ms: 503})

      saved = saved_view_fixture(scope, name: "Production", params: %{"selector" => "env=prod"})
      {token, _display_token} = display_token_fixture(scope, [saved])

      conn = get(conn, wall_path(token))
      assert html_response(conn, 200) =~ "Production"

      {:ok, view, html} = live(conn)
      assert has_element?(view, "#wall-title", "Production")
      assert has_element?(view, "#tile-#{web.id}[data-status=up]")
      assert has_element?(view, "#tile-#{db.id}[data-status=down]")
      refute html =~ "Staging"

      assert tile_text(view, web) =~ "42 ms"
      assert tile_text(view, web) =~ "100%"
      assert tile_text(view, db) =~ "Down"
      assert has_element?(view, "#wall-summary [data-status=down]", "1 down")

      # No links at all: nothing behind a login, no navigation.
      assert html |> LazyHTML.from_document() |> LazyHTML.query("a") |> Enum.count() == 0
      refute html =~ "/monitors"
      refute html =~ "Log out"
      refute has_element?(view, "#app-nav")

      # The connection lost banner, shown while disconnected.
      assert has_element?(view, "#wall-disconnected[hidden][phx-disconnected][phx-connected]")
    end

    test "updates in real time", %{conn: conn, scope: scope} do
      monitor = monitor_fixture(:http, %{name: "Web"})
      saved = saved_view_fixture(scope)
      {token, _display_token} = display_token_fixture(scope, [saved])
      {:ok, view, _html} = live(conn, wall_path(token))

      assert has_element?(view, "#tile-#{monitor.id}[data-status=pending]")

      check_result_fixture(monitor, %{status: :down, response_time_ms: 503})
      assert has_element?(view, "#tile-#{monitor.id}[data-status=down]")
      assert tile_text(view, monitor) =~ "503 ms"

      check_result_fixture(monitor, %{status: :up, response_time_ms: 40})
      assert has_element?(view, "#wall-summary", "All 1 up")

      other = monitor_fixture(:http, %{name: "New one"})
      assert has_element?(view, "#tile-#{other.id}", "New one")

      {:ok, _} = Monitoring.delete_monitor(other)
      refute has_element?(view, "#tile-#{other.id}")
    end

    test "groups by label values and shows matrices", %{conn: conn, scope: scope} do
      oslo =
        monitor_fixture(:http, %{
          name: "API Oslo",
          labels: %{"service" => "api", "site" => "oslo"}
        })

      hel =
        monitor_fixture(:http, %{name: "API Hel", labels: %{"service" => "api", "site" => "hel"}})

      check_result_fixture(oslo, %{status: :down})
      check_result_fixture(hel, %{status: :up})

      grouped = saved_view_fixture(scope, name: "By site", params: %{"group" => "site"})

      matrix =
        saved_view_fixture(scope,
          name: "Matrix",
          params: %{"group" => "service,site", "layout" => "matrix"}
        )

      {token, _} = display_token_fixture(scope, [grouped, matrix], rotate_seconds: 10)
      {:ok, view, html} = live(conn, wall_path(token))

      # Problems first, by their values only.
      assert has_element?(view, "#wall-section-0 h2", "oslo")
      assert has_element?(view, "#wall-section-1 h2", "hel")
      assert has_element?(view, "#wall-section-0 #tile-#{oslo.id}")
      refute html =~ "site="
      assert has_element?(view, "#wall-rotation[aria-label='View 1 of 2']")

      send(view.pid, :rotate)
      assert has_element?(view, "#wall-title", "Matrix")
      assert has_element?(view, "#wall-rotation[aria-label='View 2 of 2']")
      assert has_element?(view, "#wall-matrix th", "api")
      assert has_element?(view, "#wall-matrix th", "oslo")
      assert has_element?(view, "#wall-matrix td [data-status=down]", "1/1")
      refute has_element?(view, "#wall-matrix a")

      send(view.pid, :rotate)
      assert has_element?(view, "#wall-title", "By site")
    end

    test "grid views have small tiles", %{conn: conn, scope: scope} do
      monitor = monitor_fixture(:http, %{name: "Web"})
      saved = saved_view_fixture(scope, params: %{"layout" => "grid"})
      {token, _} = display_token_fixture(scope, [saved])
      {:ok, view, _html} = live(conn, wall_path(token))

      assert has_element?(view, "#tile-#{monitor.id} .sr-only", "Pending")
    end

    test "says so when there is nothing to show", %{conn: conn, scope: scope, user: user} do
      saved = saved_view_fixture(scope, name: "Empty", params: %{"selector" => "env=nope"})
      {token, display_token} = display_token_fixture(scope, [saved])
      {:ok, view, _html} = live(conn, wall_path(token))
      assert has_element?(view, "#wall-message", "No monitors in this view.")

      # A stored selector that no longer parses shows nothing, and not the selector.
      saved |> Ecto.Changeset.change(params: %{"selector" => "env=(("}) |> Repo.update!()
      send(view.pid, {:saved_views_changed})
      assert has_element?(view, "#wall-message", "filter is invalid")
      refute render(view) =~ "env=(("

      # The creator no longer sees the view: the token stops showing it.
      other = oidc_user_fixture()
      other_view = saved_view_fixture(other, visibility: :groups, groups: ["ops"])
      {:ok, _} = DisplayTokens.update_token(scope, display_token, %{view_ids: [other_view.id]})
      assert has_element?(view, "#wall-title", other_view.name)

      Accounts.upsert_oidc_user(%{
        oidc_issuer: user.oidc_issuer,
        oidc_subject: user.oidc_subject,
        email: user.email,
        groups: []
      })

      send(view.pid, :recheck)
      assert has_element?(view, "#wall-message", "views aren't available")
      refute render(view) =~ other_view.name
    end
  end

  describe "what the display never shows" do
    test "targets, labels, selectors, settings and messages", %{conn: conn, scope: scope} do
      monitor =
        monitor_fixture(:http, %{
          name: "Billing",
          description: "runbook at wiki.internal/billing",
          labels: %{"team" => "skunkworks", "env" => "prod"},
          settings: %{url: "https://user:hunter2@10.0.0.7/health"}
        })

      tcp = monitor_fixture(:tcp, %{name: "Ledger", labels: %{"env" => "prod"}})
      check_result_fixture(monitor, %{status: :down, message: "HTTP 500 from 10.0.0.7"})
      check_result_fixture(tcp, %{status: :up, message: "connected to db.example.com"})
      window_fixture(%{title: "Secret upgrade", monitor_ids: [tcp.id]})

      saved =
        saved_view_fixture(scope,
          name: "Prod",
          params: %{"selector" => "env=prod, team!=gold", "group" => "env"}
        )

      {token, _} = display_token_fixture(scope, [saved])

      dead = conn |> get(wall_path(token)) |> html_response(200)
      {:ok, view, connected} = live(conn, wall_path(token))
      Monitoring.broadcast_status_event(monitor, {:warning_raised, monitor, nil})
      check_result_fixture(monitor, %{status: :down, message: "HTTP 502 from 10.0.0.7"})
      updated = render(view)

      assert updated =~ "Billing"
      assert updated =~ "Ledger"
      assert has_element?(view, "#tile-#{tcp.id} .hero-wrench-screwdriver-micro")

      for html <- [dead, connected, updated] do
        refute html =~ "10.0.0.7"
        refute html =~ "hunter2"
        refute html =~ "/health"
        refute html =~ "db.example.com"
        refute html =~ "HTTP 50"
        refute html =~ "skunkworks"
        refute html =~ "team"
        refute html =~ "gold"
        refute html =~ "env="
        refute html =~ "runbook"
        refute html =~ "Secret upgrade"
        refute html =~ "HTTP(S)"
        refute html =~ token
      end
    end

    test "the token in logs", %{conn: conn, scope: scope} do
      saved = saved_view_fixture(scope)
      {token, display_token} = display_token_fixture(scope, [saved])

      log =
        capture_debug_log(fn ->
          conn = get(conn, wall_path(token))
          {:ok, view, _html} = live(conn)
          render(view)
          {:ok, _} = DisplayTokens.delete_token(scope, display_token)
          assert_redirect(view, wall_path(token))
          assert conn |> recycle() |> get(wall_path(token)) |> response(404)
        end)

      assert log =~ "GET /wall/[FILTERED]"
      assert log =~ "Sent 200"
      assert log =~ "Sent 404"
      # The debug logs of the router and LiveView ran, with the token filtered.
      assert log =~ "MOUNT SentinelixWeb.WallLive"
      assert log =~ ~s("token" => "[FILTERED]")
      refute log =~ token
    end

    defp capture_debug_log(fun) do
      level = Logger.level()
      Logger.configure(level: :debug)

      try do
        capture_log([level: :debug], fun)
      after
        Logger.configure(level: level)
      end
    end
  end

  describe "access" do
    test "invalid, malformed, expired and revoked tokens are the same 404", %{
      conn: conn,
      scope: scope
    } do
      saved = saved_view_fixture(scope)
      {revoked, revoked_token} = display_token_fixture(scope, [saved])
      {:ok, _} = DisplayTokens.delete_token(scope, revoked_token)
      {expired, expired_token} = display_token_fixture(scope, [saved])

      expired_token
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -60))
      |> Repo.update!()

      unknown_page = conn |> get("/no-such-page") |> response(404)

      for token <- [revoked, expired, String.duplicate("A", 43), "short", "../views"] do
        conn = get(conn, wall_path(token))
        assert response(conn, 404) == unknown_page
        assert response_content_type(conn, :html)
      end
    end

    test "sends no referrer and isn't cached", %{conn: conn, scope: scope} do
      saved = saved_view_fixture(scope)
      {token, _} = display_token_fixture(scope, [saved])

      for conn <- [get(conn, wall_path(token)), get(conn, wall_path("nope"))] do
        assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      end

      conn = get(conn, wall_path(token))
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end

    test "works without a login and ignores one", %{conn: conn, scope: scope} do
      saved = saved_view_fixture(scope, name: "Shown")
      {token, _} = display_token_fixture(scope, [saved])
      someone = user_fixture()
      _theirs = saved_view_fixture(someone, name: "Not on the wall", visibility: :shared)

      {:ok, view, html} = conn |> log_in_user(someone) |> live(wall_path(token))
      assert has_element?(view, "#wall-title", "Shown")
      refute html =~ "Not on the wall"
      refute html =~ someone.email
    end

    test "revoking the token disconnects open displays", %{conn: conn, scope: scope} do
      saved = saved_view_fixture(scope)
      {token, display_token} = display_token_fixture(scope, [saved])
      {:ok, view, _html} = live(conn, wall_path(token))

      {:ok, _} = DisplayTokens.delete_token(scope, display_token)
      assert_redirect(view, wall_path(token))
      assert conn |> get(wall_path(token)) |> response(404)
    end

    test "deleting the creator disconnects their displays", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      saved = saved_view_fixture(scope, visibility: :shared)
      {token, _display_token} = display_token_fixture(scope, [saved])
      {:ok, view, _html} = live(conn, wall_path(token))

      {:ok, _user, _sessions} = Accounts.delete_user(user)
      assert_redirect(view, wall_path(token))
    end

    test "the periodic check notices an expired token", %{conn: conn, scope: scope} do
      saved = saved_view_fixture(scope)
      {token, display_token} = display_token_fixture(scope, [saved])
      {:ok, view, _html} = live(conn, wall_path(token))

      Repo.update_all(DisplayToken,
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
      )

      assert display_token.id == Repo.one(DisplayToken).id

      send(view.pid, :recheck)
      assert_redirect(view, wall_path(token))
    end

    test "a token revoked before the display connects doesn't connect", %{
      conn: conn,
      scope: scope
    } do
      saved = saved_view_fixture(scope)
      {token, display_token} = display_token_fixture(scope, [saved])

      conn = get(conn, wall_path(token))
      assert html_response(conn, 200)

      {:ok, _} = DisplayTokens.delete_token(scope, display_token)
      assert {:error, {:redirect, %{to: to}}} = live(conn)
      assert to == wall_path(token)
    end

    test "reconnects with the token in the URL", %{conn: conn, scope: scope} do
      saved = saved_view_fixture(scope, name: "Again")
      {token, _} = display_token_fixture(scope, [saved])

      for _attempt <- 1..3 do
        {:ok, view, _html} = live(conn, wall_path(token))
        assert has_element?(view, "#wall-title", "Again")
      end
    end

    test "follows changes of the token and its views", %{conn: conn, scope: scope} do
      first = saved_view_fixture(scope, name: "First")
      second = saved_view_fixture(scope, name: "Second")
      {token, display_token} = display_token_fixture(scope, [first])
      {:ok, view, _html} = live(conn, wall_path(token))
      refute has_element?(view, "#wall-rotation")

      {:ok, _} =
        DisplayTokens.update_token(scope, display_token, %{
          view_ids: [second.id, first.id],
          rotate_seconds: 5
        })

      # Still on the view it showed, now with two to rotate through.
      assert has_element?(view, "#wall-title", "First")
      assert has_element?(view, "#wall-rotation[aria-label='View 2 of 2']")

      {:ok, _} = SavedViews.update_view(scope, first, %{name: "Renamed"})
      assert has_element?(view, "#wall-title", "Renamed")

      {:ok, _} = SavedViews.delete_view(scope, SavedViews.get_view(scope, first.slug))
      assert has_element?(view, "#wall-title", "Second")
      refute has_element?(view, "#wall-rotation")
    end
  end

  describe "rate limiting" do
    test "page loads beyond the limit get a 429 that reloads itself", %{conn: conn, scope: scope} do
      saved = saved_view_fixture(scope)
      {token, _} = display_token_fixture(scope, [saved])

      {limit, period} = Application.fetch_env!(:sentinelix, RateLimit)[:wall]
      await_rate_limit_window(:wall)
      {:allow, ^limit} = RateLimit.hit({:wall, conn.remote_ip}, period, limit, limit)

      for path <- [wall_path(token), wall_path("guess")] do
        conn = get(conn, path)
        assert conn.status == 429
        assert [retry_after] = get_resp_header(conn, "retry-after")
        assert response(conn, 429) =~ ~s(http-equiv="refresh" content="#{retry_after}")
      end

      # Other clients aren't limited.
      assert build_conn()
             |> Map.put(:remote_ip, unique_ip())
             |> get(wall_path(token))
             |> html_response(200)
    end

    test "reconnects count too", %{conn: conn, scope: scope} do
      saved = saved_view_fixture(scope)
      {token, _} = display_token_fixture(scope, [saved])

      {limit, period} = Application.fetch_env!(:sentinelix, RateLimit)[:wall]
      await_rate_limit_window(:wall)
      conn = get(conn, wall_path(token))
      assert html_response(conn, 200)

      # The page load counted one.
      {:allow, ^limit} = RateLimit.hit({:wall, conn.remote_ip}, period, limit, limit - 1)
      assert {:error, {:redirect, %{to: to}}} = live(conn)
      assert to == wall_path(token)
    end
  end

  test "server errors on a wall reload the page after a while" do
    conn = Phoenix.ConnTest.build_conn(:get, "/wall/abc")

    html =
      SentinelixWeb.ErrorHTML.render("500.html", %{conn: conn, status: 500})
      |> Phoenix.HTML.safe_to_string()

    assert html =~ ~s(http-equiv="refresh")
    assert html =~ "Internal Server Error"

    assert SentinelixWeb.ErrorHTML.render("500.html", %{conn: build_conn(:get, "/"), status: 500}) ==
             "Internal Server Error"

    assert SentinelixWeb.ErrorHTML.render("404.html", %{conn: conn, status: 404}) == "Not Found"
  end
end
