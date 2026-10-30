defmodule Sentinelix.MaintenanceTest do
  # Maintenance windows are cached globally.
  use Sentinelix.DataCase, async: false

  import Sentinelix.MaintenanceFixtures
  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Maintenance
  alias Sentinelix.Maintenance.{Cache, Window}
  alias Sentinelix.Monitoring

  setup :reset_maintenance_cache

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
end
