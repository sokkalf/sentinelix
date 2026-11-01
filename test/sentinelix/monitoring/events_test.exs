defmodule Sentinelix.Monitoring.EventsTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{Events, MonitorEvent, Warning}

  @now ~U[2026-11-01 12:00:00.000000Z]

  setup do
    %{monitor: monitor_fixture(:postgres)}
  end

  defp record(monitor, params, now \\ @now), do: Events.record_event(monitor, params, now: now)

  defp error(monitor, params) do
    {:error, changeset} = record(monitor, params)
    Events.error_message(changeset)
  end

  describe "event tokens" do
    test "are generated on demand, replaced and revoked", %{monitor: monitor} do
      assert monitor.event_token == nil
      assert Monitoring.get_monitor_by_event_token("") == nil

      Monitoring.subscribe_monitor(monitor)
      {:ok, monitor} = Monitoring.generate_event_token(monitor)
      assert_received {:monitor_updated, %{event_token: token}}
      assert is_binary(token) and byte_size(token) >= 40
      assert Monitoring.get_monitor_by_event_token(token).id == monitor.id

      {:ok, monitor} = Monitoring.generate_event_token(monitor)
      assert monitor.event_token != token
      assert Monitoring.get_monitor_by_event_token(token) == nil

      {:ok, monitor} = Monitoring.revoke_event_token(monitor)
      assert monitor.event_token == nil
    end

    test "are not inspected or cloned", %{monitor: monitor} do
      {:ok, monitor} = Monitoring.generate_event_token(monitor)
      refute inspect(monitor) =~ monitor.event_token
      assert Monitoring.clone_monitor(monitor).event_token == nil
    end
  end

  describe "record_event/3" do
    test "an info event with metadata", %{monitor: monitor} do
      Monitoring.subscribe_monitor(monitor)

      assert {:ok, %MonitorEvent{} = event, :pending} =
               record(monitor, %{
                 "title" => "  Patroni on_role_change: db1 is now primary ",
                 "message" => "",
                 "token" => "secret",
                 "action" => "on_role_change",
                 "role" => "primary"
               })

      assert event.severity == :info
      assert event.key == nil
      assert event.title == "Patroni on_role_change: db1 is now primary"
      assert event.message == nil
      assert event.metadata == %{"action" => "on_role_change", "role" => "primary"}
      assert event.occurred_at == @now
      assert_received {:event_recorded, %MonitorEvent{id: id}} when id == event.id
      refute_received {:warnings_changed, _}

      assert Events.active_warnings(monitor) == []
      assert [%{id: ^id}] = Events.list_events(monitor)
    end

    test "atom keys, JSON values and the status of the latest result", %{monitor: monitor} do
      check_result_fixture(monitor, %{status: :up})

      assert {:ok, event, :up} =
               record(monitor, %{title: "Deployed", message: "v1.2", build: 42, tags: ["a"]})

      assert event.message == "v1.2"
      assert event.metadata == %{"build" => 42, "tags" => ["a"]}
    end

    test "warning and ok events raise and clear warnings by key", %{monitor: monitor} do
      Monitoring.subscribe_monitor(monitor)

      {:ok, _event, _status} =
        record(monitor, %{"title" => "Disk 91% full", "severity" => "WARNING", "key" => "disk"})

      assert_received {:warnings_changed, id} when id == monitor.id

      {:ok, event, _status} =
        record(monitor, %{"title" => "Replication lag", "severity" => "warning"})

      assert event.key == ""

      assert [%Warning{key: "disk", title: "Disk 91% full", expires_at: nil}, %Warning{key: ""}] =
               Events.active_warnings(monitor)

      # Raising a warning again replaces it.
      {:ok, _event, _status} =
        record(
          monitor,
          %{"title" => "Disk 95% full", "severity" => "warning", "key" => "disk"},
          DateTime.add(@now, 1, :second)
        )

      assert [%Warning{key: ""}, %Warning{key: "disk", title: "Disk 95% full"}] =
               Events.active_warnings(monitor, now: @now)

      {:ok, event, _status} =
        record(monitor, %{"title" => "Disk ok", "severity" => "ok", "key" => "disk"})

      assert event.severity == :ok
      assert event.key == "disk"
      assert [%Warning{key: ""}] = Events.active_warnings(monitor)

      # An ok without a key clears the warning without a key only.
      {:ok, _event, _status} = record(monitor, %{"title" => "Lag ok", "severity" => "ok"})
      assert Events.active_warnings(monitor) == []
      assert length(Events.list_events(monitor)) == 5
    end

    test "a warning with a ttl expires", %{monitor: monitor} do
      {:ok, _event, _status} =
        record(monitor, %{"title" => "Backup late", "severity" => "warning", "ttl" => "30m"})

      assert [%Warning{expires_at: expires_at}] = Events.active_warnings(monitor, now: @now)
      assert expires_at == DateTime.add(@now, 30, :minute)
      assert Events.active_warnings(monitor, now: expires_at) == []

      Monitoring.subscribe_monitor(monitor)
      assert {:ok, []} = Events.expire_warnings(monitor, now: @now)

      assert {:ok, [%Warning{title: "Backup late"}]} =
               Events.expire_warnings(monitor, now: expires_at)

      assert_received {:event_recorded,
                       %MonitorEvent{
                         severity: :ok,
                         key: "",
                         title: "Warning expired: Backup late"
                       }}

      assert_received {:warnings_changed, _id}
      assert Repo.all(Warning) == []
    end

    test "ttl formats", %{monitor: monitor} do
      ttl = fn value ->
        {:ok, _, _} = record(monitor, %{"title" => "t", "severity" => "warning", "ttl" => value})
        [warning] = Events.active_warnings(monitor, now: @now)
        DateTime.diff(warning.expires_at, @now)
      end

      assert ttl.("90") == 90
      assert ttl.(90) == 90
      assert ttl.(" 45s ") == 45
      assert ttl.("2h") == 7_200
      assert ttl.("7D") == 7 * 86_400
    end

    test "invalid params", %{monitor: monitor} do
      assert error(monitor, %{}) == "title can't be blank"
      assert error(monitor, %{"title" => "  "}) == "title can't be blank"
      assert error(monitor, %{"title" => 42}) == "title is invalid"

      assert error(monitor, %{"title" => "t", "severity" => "critical"}) ==
               "severity must be info, warning or ok"

      assert error(monitor, %{"title" => "t", "ttl" => "5m"}) ==
               "ttl is only allowed with severity warning"

      for ttl <- ["0", "-5", "5 weeks", "366d", 1.5, "x"] do
        assert error(monitor, %{"title" => "t", "severity" => "warning", "ttl" => ttl}) =~
                 "ttl must be a duration"
      end

      assert error(monitor, %{
               "title" => "t",
               "severity" => "warning",
               "key" => String.duplicate("k", 101)
             }) =~
               "key should be at most 100 character(s)"

      many = Map.new(1..51, &{"field#{&1}", "x"})
      assert error(monitor, Map.put(many, "title", "t")) == "metadata can have at most 50 fields"

      assert error(monitor, %{"title" => "t", "big" => String.duplicate("x", 9_000)}) ==
               "metadata must be at most 8192 bytes"

      assert Events.list_events(monitor) == []
    end

    test "long titles and messages are cut", %{monitor: monitor} do
      {:ok, event, _status} =
        record(monitor, %{
          "title" => String.duplicate("t", 300),
          "message" => String.duplicate("m", 5_000)
        })

      assert String.length(event.title) == 255
      assert String.length(event.message) == 4_000
    end
  end

  describe "clear_warnings/3" do
    test "clears all or some warnings, logging who did", %{monitor: monitor} do
      for key <- ["a", "b", "c"] do
        {:ok, _, _} =
          record(monitor, %{"title" => "Warning #{key}", "severity" => "warning", "key" => key})
      end

      assert {:ok, [%Warning{key: "b"}]} =
               Events.clear_warnings(monitor, ["b"], by: "ops@example.com", now: @now)

      assert [
               %MonitorEvent{severity: :ok, key: "b", title: "Warning cleared: Warning b"} = event
               | _
             ] =
               Events.list_events(monitor)

      assert event.metadata == %{"cleared_by" => "ops@example.com"}

      assert {:ok, cleared} = Events.clear_warnings(monitor)
      assert cleared |> Enum.map(& &1.key) |> Enum.sort() == ["a", "c"]
      assert Events.active_warnings(monitor) == []
      assert {:ok, []} = Events.clear_warnings(monitor)
    end
  end

  test "events and warnings are deleted with the monitor", %{monitor: monitor} do
    {:ok, _, _} = record(monitor, %{"title" => "t", "severity" => "warning"})
    {:ok, _} = Monitoring.delete_monitor(monitor)

    assert Repo.all(MonitorEvent) == []
    assert Repo.all(Warning) == []
  end

  test "prune_events/1 deletes events before the cutoff", %{monitor: monitor} do
    {:ok, old, _} = record(monitor, %{"title" => "old"}, DateTime.add(@now, -10, :day))
    {:ok, new, _} = record(monitor, %{"title" => "new"})

    assert Events.prune_events(DateTime.add(@now, -1, :day)) == 1
    assert Enum.map(Events.list_events(monitor), & &1.id) == [new.id]
    refute Repo.get(MonitorEvent, old.id)
  end
end
