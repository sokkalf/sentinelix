defmodule Sentinelix.MaintenanceTest do
  # Maintenance windows are cached globally.
  use Sentinelix.DataCase, async: false

  import Sentinelix.MaintenanceFixtures
  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Maintenance
  alias Sentinelix.Maintenance.{Cache, Window}
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Selector

  setup :reset_maintenance_cache

  describe "default_timezone/1" do
    test "uses a known time zone and falls back to UTC" do
      assert Maintenance.default_timezone() == "Etc/UTC"
      assert Maintenance.default_timezone("Europe/Oslo") == "Europe/Oslo"
      assert Maintenance.default_timezone("Mars/Olympus_Mons") == "Etc/UTC"
      assert Maintenance.default_timezone(nil) == "Etc/UTC"
      assert Maintenance.new_window().timezone == "Etc/UTC"
    end
  end

  describe "CRUD" do
    test "create_window/1 attaches monitors" do
      a = monitor_fixture()
      b = monitor_fixture()

      assert {:ok, window} =
               Maintenance.create_window(%{
                 "title" => "  DB upgrade ",
                 "starts_at" => "2026-11-01T22:00:00Z",
                 "ends_at" => "2026-11-01T23:00:00Z",
                 "monitor_ids" => ["#{a.id}", "#{b.id}", ""]
               })

      assert window.title == "DB upgrade"
      assert window.monitors |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert [%Window{id: id}] = Maintenance.list_windows()
      assert id == window.id
    end

    test "create_window/1 requires monitors unless it applies to all" do
      assert {:error, changeset} =
               Maintenance.create_window(%{
                 title: "x",
                 starts_at: ~U[2026-11-01 22:00:00Z],
                 ends_at: ~U[2026-11-01 23:00:00Z]
               })

      assert errors_on(changeset).monitors != []
    end

    test "create_window/1 with a selector instead of monitors" do
      assert {:ok, window} =
               Maintenance.create_window(%{
                 "title" => "Oslo",
                 "starts_at" => "2026-11-01T22:00:00Z",
                 "ends_at" => "2026-11-01T23:00:00Z",
                 "selector" => "Site=oslo"
               })

      assert window.selector == "site=oslo"
      assert window.monitors == []

      assert {:error, changeset} =
               Maintenance.create_window(%{
                 title: "Down",
                 starts_at: ~U[2026-11-01 22:00:00Z],
                 ends_at: ~U[2026-11-01 23:00:00Z],
                 selector: "status=down"
               })

      assert ["status can't be used here at column 1"] = errors_on(changeset).selector
    end

    test "selector_monitors/1 previews the matching monitors" do
      a = monitor_fixture(:http, %{name: "B web", labels: %{"site" => "oslo"}})
      b = monitor_fixture(:http, %{name: "A db", labels: %{"site" => "oslo"}})
      _other = monitor_fixture(:http, %{labels: %{"site" => "bergen"}})

      assert Enum.map(Maintenance.selector_monitors("site=oslo"), & &1.id) == [b.id, a.id]

      assert Maintenance.selector_monitors(Selector.parse!("name~web")) |> Enum.map(& &1.id) == [
               a.id
             ]

      assert Maintenance.selector_monitors("") == []
      assert Maintenance.selector_monitors("site=") == []
      assert Maintenance.selector_monitors("status=down") == []
      assert Maintenance.selector_monitors(Selector.parse!("status=down")) == []
    end

    test "update_window/2 replaces monitors only when given" do
      a = monitor_fixture()
      b = monitor_fixture()
      window = window_fixture(%{monitor_ids: [a.id]})

      {:ok, window} = Maintenance.update_window(window, %{title: "Renamed"})
      assert Enum.map(window.monitors, & &1.id) == [a.id]

      {:ok, window} = Maintenance.update_window(window, %{monitor_ids: [b.id]})
      assert Enum.map(Maintenance.get_window!(window.id).monitors, & &1.id) == [b.id]
    end

    test "delete_window/1 and deleting monitors" do
      a = monitor_fixture()
      b = monitor_fixture()
      window = window_fixture(%{monitor_ids: [a.id, b.id]})

      {:ok, _} = Monitoring.delete_monitor(a)
      assert Enum.map(Maintenance.get_window(window.id).monitors, & &1.id) == [b.id]

      {:ok, _} = Maintenance.delete_window(window)
      assert Maintenance.get_window(window.id) == nil
    end

    test "changes are broadcast" do
      :ok = Maintenance.subscribe()
      window = window_fixture(%{all_monitors: true, enabled: false})
      assert_receive {:maintenance_changed}

      {:ok, _} = Maintenance.delete_window(window)
      assert_receive {:maintenance_changed}
    end
  end

  test "the application's engine is configured with this module" do
    assert Sentinelix.Monitoring.Supervisor.config().maintenance == Maintenance
  end

  describe "active?/2 and the cache" do
    test "uses the cached windows of the monitor" do
      monitor = monitor_fixture()
      other = monitor_fixture()
      window = window_fixture(%{monitor_ids: [monitor.id]})
      now = DateTime.utc_now()

      assert Maintenance.active?(monitor, now)
      assert Maintenance.active?(monitor.id, now)
      refute Maintenance.active?(other, now)
      refute Maintenance.active?(monitor, DateTime.add(now, 2, :hour))

      # Updates refresh the cache.
      {:ok, _} = Maintenance.update_window(window, %{enabled: false})
      refute Maintenance.active?(monitor, now)
      assert Cache.windows() == []
    end

    test "all-monitors windows apply to every monitor, including new ones" do
      window_fixture(%{all_monitors: true})
      assert Maintenance.active?(monitor_fixture(), DateTime.utc_now())
    end

    test "selector windows apply to monitors created later with matching labels" do
      window = window_fixture(%{selector: "site=oslo, !legacy"})
      :ok = Maintenance.subscribe()
      now = DateTime.utc_now()

      oslo = monitor_fixture(:http, %{labels: %{"site" => "oslo"}})
      bergen = monitor_fixture(:http, %{labels: %{"site" => "bergen"}})

      # The engine passes the struct: in maintenance right away.
      assert Maintenance.active?(oslo, now)
      refute Maintenance.active?(bergen, now)

      # The cache recomputed the matches from the "monitors" events, for
      # lookups by id (badges) and broadcast the change.
      sync_cache()
      assert_received {:maintenance_changed}
      assert Maintenance.active?(oslo.id, now)
      refute Maintenance.active?(bergen.id, now)
      assert Map.keys(Maintenance.active_windows_for([oslo.id, bergen.id])) == [oslo.id]
      assert [%{id: id, selector_ids: [oslo_id]}] = Cache.windows()
      assert {id, oslo_id} == {window.id, oslo.id}
    end

    test "selector membership follows label, name and bulk changes and deletes" do
      window_fixture(%{selector: "site=oslo"})
      named = window_fixture(%{selector: "name~edge"})
      a = monitor_fixture(:http, %{name: "a", labels: %{"site" => "bergen"}})
      b = monitor_fixture(:http, %{name: "b"})
      c = monitor_fixture(:http, %{name: "c", labels: %{"site" => "oslo"}})
      now = DateTime.utc_now()

      matching = fn ->
        sync_cache()
        [a, b, c] |> Enum.map(& &1.id) |> Enum.filter(&Maintenance.active?(&1, now))
      end

      assert matching.() == [c.id]

      {:ok, a} = Monitoring.update_monitor(a, %{labels: %{"site" => "oslo"}})
      assert Maintenance.active?(a, now)
      assert matching.() == [a.id, c.id]

      {:ok, [_b]} = Monitoring.put_labels([b, c], ["site=oslo"])
      assert matching.() == [a.id, b.id, c.id]

      {:ok, [_a, _b, _c]} = Monitoring.delete_labels([a, b, c], ["site"])
      assert matching.() == []

      # Renamed into the name selector.
      {:ok, b} = Monitoring.update_monitor(b, %{name: "edge-1"})
      assert matching.() == [b.id]
      assert [%{selector_ids: [b_id]}] = Enum.filter(Cache.windows(), &(&1.id == named.id))
      assert b_id == b.id

      {:ok, _} = Monitoring.delete_monitor(b)
      assert matching.() == []
      assert Enum.all?(Cache.windows(), &(&1.selector_ids == []))
    end

    test "a selector adds to the attached monitors" do
      attached = monitor_fixture()
      labeled = monitor_fixture(:http, %{labels: %{"env" => "prod"}})
      other = monitor_fixture()
      window_fixture(%{monitor_ids: [attached.id], selector: "env=prod"})
      now = DateTime.utc_now()

      for monitor <- [attached, labeled], do: assert(Maintenance.active?(monitor, now))
      for monitor <- [attached, labeled], do: assert(Maintenance.active?(monitor.id, now))
      refute Maintenance.active?(other, now)
      refute Maintenance.active?(other.id, now)
    end

    test "monitor changes don't reload the cache without selector windows" do
      window_fixture(%{all_monitors: true})
      :ok = Maintenance.subscribe()

      monitor_fixture(:http, %{labels: %{"site" => "oslo"}})
      sync_cache()
      refute_received {:maintenance_changed}
    end

    test "doesn't query the database" do
      monitor = monitor_fixture()
      window_fixture(%{monitor_ids: [monitor.id]})

      ref = make_ref()
      parent = self()
      handler = "maintenance-test-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:sentinelix, :repo, :query],
        fn _, _, _, _ ->
          send(parent, {:query, ref})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert Maintenance.active?(monitor, DateTime.utc_now())
      refute_received {:query, ^ref}

      # Nor do selectors.
      window_fixture(%{selector: "site=oslo"})
      monitor = monitor_fixture(:http, %{labels: %{"site" => "oslo"}})
      sync_cache()
      flush_queries(ref)

      assert Maintenance.active?(monitor, DateTime.utc_now())
      assert Maintenance.active?(monitor.id, DateTime.utc_now())
      refute_received {:query, ^ref}
    end

    test "active_windows_for/2" do
      a = monitor_fixture()
      b = monitor_fixture()
      c = monitor_fixture()
      window = window_fixture(%{monitor_ids: [a.id]})
      all = window_fixture(%{all_monitors: true, title: "All"})

      _future =
        window_fixture(%{
          monitor_ids: [c.id],
          starts_at: DateTime.add(DateTime.utc_now(), 1, :day),
          ends_at: DateTime.add(DateTime.utc_now(), 2, :day)
        })

      result = Maintenance.active_windows_for([a.id, b.id])

      assert result |> Map.fetch!(a.id) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([window.id, all.id])

      assert result |> Map.fetch!(b.id) |> Enum.map(& &1.id) == [all.id]

      {:ok, _} = Maintenance.delete_window(all)
      assert Maintenance.active_windows_for([b.id, c.id]) == %{}
      assert Enum.map(Maintenance.active_windows(), & &1.id) == [window.id]
    end

    test "the minute tick reloads and broadcasts window starts and ends" do
      monitor = monitor_fixture()
      window = window_fixture(%{monitor_ids: [monitor.id]})
      :ok = Maintenance.subscribe()

      # Nothing changed: no broadcast.
      send(Cache, :tick)
      refute_receive {:maintenance_changed}, 50

      # A change made behind the context's back (e.g. the window ended).
      Repo.update_all(Window,
        set: [
          ends_at: DateTime.add(DateTime.utc_now(), -1, :minute),
          starts_at: DateTime.add(DateTime.utc_now(), -2, :minute)
        ]
      )

      send(Cache, :tick)
      assert_receive {:maintenance_changed}
      refute Maintenance.active?(monitor, DateTime.utc_now())
      assert [%{id: id}] = Cache.windows()
      assert id == window.id
    end
  end

  # Waits until the cache has handled the monitor events sent so far.
  defp sync_cache, do: :sys.get_state(Cache)

  defp flush_queries(ref) do
    receive do
      {:query, ^ref} -> flush_queries(ref)
    after
      0 -> :ok
    end
  end
end
