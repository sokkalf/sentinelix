defmodule Sentinelix.MonitoringTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{CheckResult, Incident, Monitor, Settings}

  describe "list_monitors/1" do
    test "returns all monitors ordered by name, case-insensitively" do
      b = monitor_fixture(:http, %{name: "beta"})
      a = monitor_fixture(:http, %{name: "Alpha"})
      c = monitor_fixture(:tcp, %{name: "charlie", enabled: false})

      assert Enum.map(Monitoring.list_monitors(), & &1.id) == [a.id, b.id, c.id]
    end

    test "filters by enabled and type" do
      http = monitor_fixture(:http)
      tcp = monitor_fixture(:tcp)
      disabled = monitor_fixture(:ping, %{enabled: false})

      assert ids(Monitoring.list_monitors(enabled: true)) == ids([http, tcp])
      assert ids(Monitoring.list_monitors(enabled: false)) == ids([disabled])
      assert ids(Monitoring.list_monitors(type: :tcp)) == ids([tcp])
      assert ids(Monitoring.list_monitors(type: [:tcp, :ping])) == ids([tcp, disabled])
    end

    test "filters by label" do
      prod = monitor_fixture(:http, %{labels: %{"env" => "prod", "site" => "oslo"}})
      dev = monitor_fixture(:http, %{labels: %{"env" => "dev", "legacy" => ""}})
      _none = monitor_fixture(:http)

      assert ids(Monitoring.list_monitors(label: {"env", "prod"})) == ids([prod])
      assert ids(Monitoring.list_monitors(label: {"env", ""})) == ids([prod, dev])
      assert ids(Monitoring.list_monitors(label: {"legacy", ""})) == ids([dev])
      assert Monitoring.list_monitors(label: {"env", "Prod"}) == []

      assert ids(Monitoring.list_monitors(label: {"env", ""}, label: {"site", "oslo"})) ==
               ids([prod])
    end
  end

  describe "list_label_values/0" do
    test "returns the keys in use with their sorted values" do
      assert Monitoring.list_label_values() == %{}

      monitor_fixture(:http, %{labels: %{"env" => "prod", "site" => "oslo"}})
      monitor_fixture(:http, %{labels: %{"env" => "dev", "legacy" => ""}})
      monitor_fixture(:http, %{labels: %{"env" => "prod"}})

      assert Monitoring.list_label_values() == %{
               "env" => ["dev", "prod"],
               "legacy" => [""],
               "site" => ["oslo"]
             }
    end
  end

  describe "get_monitor!/1 and get_monitor/1" do
    test "return the monitor with the given id" do
      monitor = monitor_fixture()
      assert Monitoring.get_monitor!(monitor.id) == monitor
      assert Monitoring.get_monitor(monitor.id) == monitor
    end

    test "handle missing monitors" do
      assert_raise Ecto.NoResultsError, fn -> Monitoring.get_monitor!(-1) end
      assert Monitoring.get_monitor(-1) == nil
    end
  end

  describe "create_monitor/1" do
    test "with valid data creates a monitor with defaults" do
      assert {:ok, %Monitor{} = monitor} =
               Monitoring.create_monitor(%{
                 "name" => "  Example  ",
                 "type" => "http",
                 "labels" => %{" Env " => " prod ", "web" => nil},
                 "settings" => %{"url" => "https://example.com"}
               })

      assert monitor.name == "Example"
      assert monitor.type == :http
      assert monitor.enabled
      assert monitor.interval_seconds == 60
      assert monitor.retry_interval_seconds == 60
      assert monitor.max_retries == 0
      assert monitor.timeout_ms == 30_000
      assert monitor.labels == %{"env" => "prod", "web" => ""}

      assert %Settings{
               url: "https://example.com",
               method: "GET",
               headers: %{},
               accepted_status_codes: [],
               follow_redirects: true,
               max_redirects: 10,
               verify_tls: true,
               host: nil
             } = monitor.settings

      # Settings round-trip through the database.
      assert Monitoring.get_monitor!(monitor.id).settings == monitor.settings
    end

    test "requires name and type" do
      assert {:error, changeset} = Monitoring.create_monitor(%{})
      assert %{name: ["can't be blank"], type: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects unknown types" do
      assert {:error, changeset} =
               Monitoring.create_monitor(valid_monitor_attrs(:http, %{type: "smtp"}))

      assert "is invalid" in errors_on(changeset).type
    end

    test "validates intervals, retries and timeout" do
      attrs =
        valid_monitor_attrs(:http, %{
          interval_seconds: 19,
          retry_interval_seconds: 0,
          max_retries: -1,
          timeout_ms: 0
        })

      assert {:error, changeset} = Monitoring.create_monitor(attrs)
      errors = errors_on(changeset)
      assert "must be greater than or equal to 20" in errors.interval_seconds
      assert "must be greater than or equal to 20" in errors.retry_interval_seconds
      assert "must be greater than or equal to 0" in errors.max_retries
      assert "must be greater than or equal to 100" in errors.timeout_ms
    end

    test "rejects a timeout longer than the interval" do
      attrs = valid_monitor_attrs(:http, %{interval_seconds: 30, timeout_ms: 30_001})
      assert {:error, changeset} = Monitoring.create_monitor(attrs)
      assert "must not be longer than the check interval" in errors_on(changeset).timeout_ms

      attrs = valid_monitor_attrs(:http, %{interval_seconds: 30, timeout_ms: 30_000})
      assert {:ok, _} = Monitoring.create_monitor(attrs)
    end

    test "validates settings even when none are given" do
      assert {:error, changeset} =
               Monitoring.create_monitor(%{name: "No settings", type: :http})

      assert %{settings: %{url: ["can't be blank"]}} = errors_on(changeset)
    end

    test "broadcasts :monitor_created on the monitors topic" do
      Monitoring.subscribe_monitors()
      monitor = monitor_fixture()
      assert_receive {:monitor_created, ^monitor}
    end

    test "does not broadcast on failure" do
      Monitoring.subscribe_monitors()
      # Other async tests create monitors too, so only look for this one.
      name = "Invalid #{System.unique_integer([:positive])}"
      assert {:error, _} = Monitoring.create_monitor(%{name: name})
      refute_receive {:monitor_created, %{name: ^name}}
    end
  end

  describe "update_monitor/2" do
    test "with valid data updates the monitor and broadcasts" do
      monitor = monitor_fixture()
      Monitoring.subscribe_monitors()
      Monitoring.subscribe_monitor(monitor)

      assert {:ok, updated} =
               Monitoring.update_monitor(monitor, %{
                 name: "Renamed",
                 settings: %{method: "post", body: ~s({"a":1})}
               })

      assert updated.name == "Renamed"
      # Unchanged settings are kept; method is normalized.
      assert updated.settings.url == monitor.settings.url
      assert updated.settings.method == "POST"
      assert updated.settings.body == ~s({"a":1})

      assert_receive {:monitor_updated, ^updated}
      assert_receive {:monitor_updated, ^updated}
    end

    test "replaces the labels and validates them" do
      monitor = monitor_fixture(:http, %{labels: %{"env" => "prod", "site" => "oslo"}})

      assert {:ok, updated} = Monitoring.update_monitor(monitor, %{labels: ["env=dev", "legacy"]})
      assert updated.labels == %{"env" => "dev", "legacy" => ""}
      assert Monitoring.get_monitor!(monitor.id).labels == updated.labels

      assert {:error, changeset} =
               Monitoring.update_monitor(updated, %{labels: ["env=dev", "ENV=prod"]})

      assert %{labels: ["duplicate label key env"]} = errors_on(changeset)

      assert {:error, changeset} = Monitoring.update_monitor(updated, %{labels: ["bad key"]})
      assert %{labels: [~s(invalid label key "bad key")]} = errors_on(changeset)
    end

    test "with invalid data returns an error changeset" do
      monitor = monitor_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Monitoring.update_monitor(monitor, %{settings: %{url: "not a url"}})

      assert Monitoring.get_monitor!(monitor.id) == monitor
    end

    test "changing the type revalidates and resets settings" do
      monitor = monitor_fixture(:http)

      assert {:error, changeset} = Monitoring.update_monitor(monitor, %{type: :tcp})

      assert %{settings: %{host: ["can't be blank"], port: ["can't be blank"]}} =
               errors_on(changeset)

      assert {:ok, tcp} =
               Monitoring.update_monitor(monitor, %{
                 type: :tcp,
                 settings: %{host: "example.com", port: 22}
               })

      assert %Settings{host: "example.com", port: 22, url: nil, method: nil, headers: nil} =
               tcp.settings

      assert Monitoring.get_monitor!(monitor.id).settings == tcp.settings
    end
  end

  describe "secrets" do
    test "are stored encrypted and never in the settings" do
      monitor = monitor_fixture(:postgres, %{secrets: %{password: "s3cret pw"}})

      assert Monitor.secret(monitor, "password") == "s3cret pw"
      assert Monitor.secret(Monitoring.get_monitor!(monitor.id), "password") == "s3cret pw"

      %{rows: [[settings, raw]]} =
        Repo.query!("SELECT settings::text, secrets FROM monitors WHERE id = $1", [monitor.id])

      refute settings =~ "s3cret"
      refute raw =~ "s3cret"
      refute inspect(monitor) =~ "s3cret"
    end

    test "a blank value keeps the stored secret, clear_<key> removes it" do
      monitor = monitor_fixture(:postgres, %{secrets: %{"password" => "one"}})

      {:ok, monitor} = Monitoring.update_monitor(monitor, %{"secrets" => %{"password" => ""}})
      assert Monitor.secret(monitor, "password") == "one"

      {:ok, monitor} = Monitoring.update_monitor(monitor, %{name: "Renamed"})
      assert Monitor.secret(monitor, "password") == "one"

      {:ok, monitor} = Monitoring.update_monitor(monitor, %{"secrets" => %{"password" => "two"}})
      assert Monitor.secret(monitor, "password") == "two"

      {:ok, monitor} =
        Monitoring.update_monitor(monitor, %{
          "secrets" => %{"password" => "", "clear_password" => "true"}
        })

      assert Monitor.secret(monitor, "password") == nil
      assert Monitoring.get_monitor!(monitor.id).secrets == %{}
    end

    test "are dropped when they don't apply to the type" do
      assert monitor_fixture(:http, %{secrets: %{password: "x"}}).secrets == %{}

      monitor = monitor_fixture(:postgres, %{secrets: %{password: "x"}})

      {:ok, monitor} =
        Monitoring.update_monitor(monitor, %{type: :tcp, settings: %{host: "db", port: 5432}})

      assert monitor.secrets == %{}
    end

    test "are redacted in changesets" do
      changeset =
        Monitoring.change_monitor(
          %Monitor{},
          valid_monitor_attrs(:postgres, %{secrets: %{password: "s3cret"}})
        )

      refute inspect(changeset) =~ "s3cret"
    end
  end

  describe "toggle_monitor/1" do
    test "flips enabled and broadcasts :monitor_updated" do
      monitor = monitor_fixture()
      Monitoring.subscribe_monitors()

      assert {:ok, %Monitor{enabled: false} = disabled} = Monitoring.toggle_monitor(monitor)
      assert_receive {:monitor_updated, ^disabled}

      assert {:ok, %Monitor{enabled: true}} = Monitoring.toggle_monitor(disabled)
      assert Monitoring.get_monitor!(monitor.id).enabled
    end
  end

  describe "delete_monitor/1" do
    test "deletes the monitor, its results and incidents, and broadcasts" do
      monitor = monitor_fixture()
      check_result_fixture(monitor)
      incident_fixture(monitor)
      Monitoring.subscribe_monitors()
      Monitoring.subscribe_monitor(monitor)

      assert {:ok, %Monitor{}} = Monitoring.delete_monitor(monitor)
      assert_raise Ecto.NoResultsError, fn -> Monitoring.get_monitor!(monitor.id) end
      assert Repo.aggregate(CheckResult, :count) == 0
      assert Repo.aggregate(Incident, :count) == 0

      assert_receive {:monitor_deleted, %Monitor{id: id}} when id == monitor.id
      assert_receive {:monitor_deleted, %Monitor{id: ^id}}
    end
  end

  describe "change_monitor/2" do
    test "returns a changeset" do
      assert %Ecto.Changeset{} = Monitoring.change_monitor(monitor_fixture())
      assert %Ecto.Changeset{valid?: false} = Monitoring.change_monitor(%Monitor{})
    end
  end

  describe "get_monitor_by_push_token/1" do
    test "finds push monitors by token" do
      monitor = monitor_fixture(:push)
      _other = monitor_fixture(:push)

      assert Monitoring.get_monitor_by_push_token(monitor.settings.push_token).id == monitor.id
      assert Monitoring.get_monitor_by_push_token("does-not-exist-at-all") == nil
    end

    test "push tokens are unique" do
      monitor = monitor_fixture(:push)

      assert {:error, changeset} =
               Monitoring.create_monitor(
                 valid_monitor_attrs(:push, %{
                   settings: %{push_token: monitor.settings.push_token}
                 })
               )

      assert "push token is already in use" in errors_on(changeset).settings
    end
  end

  describe "record_result/2" do
    test "stores a result and broadcasts it on the monitor topic" do
      monitor = monitor_fixture()
      Monitoring.subscribe_monitor(monitor)

      assert {:ok, %CheckResult{} = result} =
               Monitoring.record_result(monitor, %{
                 status: :up,
                 response_time_ms: 42,
                 status_code: 200,
                 message: "OK"
               })

      assert result.monitor_id == monitor.id
      assert %DateTime{} = result.checked_at
      assert_receive {:check_result, ^result}
    end

    test "accepts a monitor id and an explicit checked_at" do
      monitor = monitor_fixture()
      checked_at = ~U[2026-01-01 12:00:00.123456Z]

      assert {:ok, result} =
               Monitoring.record_result(monitor.id, %{status: "down", checked_at: checked_at})

      assert result.status == :down
      assert result.checked_at == checked_at
    end

    test "validates the result" do
      monitor = monitor_fixture()

      assert {:error, changeset} =
               Monitoring.record_result(monitor, %{status: :sideways, response_time_ms: -1})

      assert %{status: ["is invalid"], response_time_ms: [_]} = errors_on(changeset)
    end

    test "truncates long messages" do
      monitor = monitor_fixture()

      {:ok, result} =
        Monitoring.record_result(monitor, %{
          status: :down,
          message: "x" <> String.duplicate("y", 5_000)
        })

      assert String.length(result.message) == 2_000
      assert String.ends_with?(result.message, "…")
    end

    test "fails for a deleted monitor" do
      monitor = monitor_fixture()
      {:ok, _} = Monitoring.delete_monitor(monitor)

      assert {:error, changeset} = Monitoring.record_result(monitor, %{status: :up})
      assert %{monitor: ["does not exist"]} = errors_on(changeset)
    end
  end

  describe "latest_results/2" do
    test "returns the newest results of a monitor first, limited" do
      monitor = monitor_fixture()
      other = monitor_fixture()
      now = DateTime.utc_now()

      results =
        for i <- 1..5 do
          check_result_fixture(monitor, %{checked_at: DateTime.add(now, i, :second)})
        end

      check_result_fixture(other)

      assert Monitoring.latest_results(monitor) == Enum.reverse(results)
      assert Monitoring.latest_results(monitor, 2) == results |> Enum.reverse() |> Enum.take(2)
      assert Monitoring.get_latest_result(monitor) == List.last(results)
      assert Monitoring.get_latest_result(monitor_fixture()) == nil
    end
  end

  describe "latest_result_per_monitor/0" do
    test "returns the most recent result for each monitor" do
      a = monitor_fixture()
      b = monitor_fixture()
      _no_results = monitor_fixture()
      now = DateTime.utc_now()

      check_result_fixture(a, %{checked_at: DateTime.add(now, -10, :second)})
      latest_a = check_result_fixture(a, %{status: :down, checked_at: now})
      latest_b = check_result_fixture(b, %{checked_at: now})

      assert Monitoring.latest_result_per_monitor() == %{a.id => latest_a, b.id => latest_b}
    end
  end

  describe "incidents" do
    test "open_incident/2 opens an incident and broadcasts" do
      monitor = monitor_fixture()
      Monitoring.subscribe_monitor(monitor)

      assert {:ok, %Incident{} = incident} =
               Monitoring.open_incident(monitor, %{
                 from_status: :up,
                 to_status: :down,
                 message: "HTTP 500"
               })

      assert incident.monitor_id == monitor.id
      assert %DateTime{} = incident.started_at
      assert incident.resolved_at == nil
      assert_receive {:incident_opened, ^incident}
      assert Monitoring.get_open_incident(monitor) == incident
    end

    test "open_incident/2 validates statuses" do
      monitor = monitor_fixture()
      assert {:error, changeset} = Monitoring.open_incident(monitor, %{to_status: :nope})
      assert %{from_status: ["can't be blank"], to_status: ["is invalid"]} = errors_on(changeset)
    end

    test "only one incident can be open per monitor" do
      monitor = monitor_fixture()
      incident_fixture(monitor)

      assert {:error, changeset} =
               Monitoring.open_incident(monitor, %{from_status: :pending, to_status: :down})

      assert "already has an open incident" in errors_on(changeset).monitor_id

      # Other monitors are unaffected.
      assert {:ok, _} =
               Monitoring.open_incident(monitor_fixture(), %{from_status: :up, to_status: :down})
    end

    test "resolve_incident/2 resolves and broadcasts; a new incident can then be opened" do
      monitor = monitor_fixture()
      incident = incident_fixture(monitor)
      Monitoring.subscribe_monitor(monitor)

      assert {:ok, %Incident{resolved_at: %DateTime{}} = resolved} =
               Monitoring.resolve_incident(incident)

      assert_receive {:incident_resolved, ^resolved}
      assert Monitoring.get_open_incident(monitor) == nil
      assert {:error, :already_resolved} = Monitoring.resolve_incident(resolved)

      assert {:ok, _} =
               Monitoring.open_incident(monitor, %{from_status: :up, to_status: :down})
    end

    test "resolve_incident/2 accepts resolved_at and rejects one before started_at" do
      monitor = monitor_fixture()
      started_at = ~U[2026-01-01 12:00:00.000000Z]
      incident = incident_fixture(monitor, %{started_at: started_at})

      assert {:error, changeset} =
               Monitoring.resolve_incident(incident,
                 resolved_at: DateTime.add(started_at, -1, :second)
               )

      assert %{resolved_at: ["must not be before the incident started"]} = errors_on(changeset)

      resolved_at = DateTime.add(started_at, 90, :second)
      assert {:ok, resolved} = Monitoring.resolve_incident(incident, resolved_at: resolved_at)
      assert resolved.resolved_at == resolved_at
    end

    test "list_incidents/2 returns the newest incidents first" do
      monitor = monitor_fixture()
      t0 = ~U[2026-01-01 12:00:00.000000Z]

      first = incident_fixture(monitor, %{started_at: t0})
      {:ok, first} = Monitoring.resolve_incident(first, resolved_at: DateTime.add(t0, 60))
      second = incident_fixture(monitor, %{started_at: DateTime.add(t0, 120)})
      incident_fixture(monitor_fixture())

      assert Monitoring.list_incidents(monitor) == [second, first]
      assert Monitoring.list_incidents(monitor, 1) == [second]
    end
  end

  defp ids(monitors), do: monitors |> Enum.map(& &1.id) |> Enum.sort()
end
