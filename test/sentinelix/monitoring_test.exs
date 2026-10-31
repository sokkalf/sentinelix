defmodule Sentinelix.MonitoringTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{CheckResult, Incident, Monitor, Selector, Settings}

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

    test "filters by automatic labels like user labels" do
      web = monitor_fixture(:http, %{labels: %{"env" => "prod"}})
      db = monitor_fixture(:tcp, %{settings: %{host: "DB.example.com", port: 5432}})
      push = monitor_fixture(:push)

      assert ids(Monitoring.list_monitors(label: {"type", "http"})) == ids([web])
      assert ids(Monitoring.list_monitors(label: {"host", "db.example.com"})) == ids([db])
      assert ids(Monitoring.list_monitors(label: {"host", ""})) == ids([web, db])
      assert ids(Monitoring.list_monitors(label: {"type", ""})) == ids([web, db, push])

      assert ids(Monitoring.list_monitors(label: {"type", "http"}, label: {"env", "prod"})) ==
               ids([web])
    end

    test "filters by selector" do
      web = monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod"}})
      db = monitor_fixture(:tcp, %{name: "Database", labels: %{"env" => "dev"}})

      assert ids(Monitoring.list_monitors(selector: "env=prod")) == ids([web])
      assert ids(Monitoring.list_monitors(selector: "type=tcp, name~base")) == ids([db])
      assert ids(Monitoring.list_monitors(selector: Selector.parse!(""))) == ids([web, db])

      assert_raise Selector.Error, fn -> Monitoring.list_monitors(selector: "env=") end
      assert_raise ArgumentError, fn -> Monitoring.list_monitors(selector: "status=up") end
    end
  end

  describe "list_label_values/1" do
    test "includes automatic labels when asked to" do
      monitor_fixture(:http, %{labels: %{"env" => "prod"}})
      monitor_fixture(:tcp)

      assert Monitoring.list_label_values(automatic: true) == %{
               "env" => ["prod"],
               "host" => ["db.example.com", "example.com"],
               "type" => ["http", "tcp"]
             }
    end

    test "returns the user label keys in use with their sorted values" do
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

    test "derives the automatic labels and keeps all_labels in sync" do
      monitor = monitor_fixture(:http, %{labels: %{"env" => "prod"}})

      assert monitor.auto_labels == %{"type" => "http", "host" => "example.com"}

      assert monitor.all_labels ==
               %{"env" => "prod", "type" => "http", "host" => "example.com"}

      assert {:ok, updated} =
               Monitoring.update_monitor(monitor, %{
                 type: :tcp,
                 settings: %{host: "DB.Example.com.", port: 5432}
               })

      assert updated.auto_labels == %{"type" => "tcp", "host" => "db.example.com"}

      assert updated.all_labels ==
               %{"env" => "prod", "type" => "tcp", "host" => "db.example.com"}

      assert Monitoring.get_monitor!(monitor.id).all_labels == updated.all_labels

      assert {:ok, toggled} = Monitoring.toggle_monitor(updated)
      assert toggled.all_labels == updated.all_labels

      assert {:ok, push} = Monitoring.update_monitor(toggled, %{type: :push})
      assert push.all_labels == %{"env" => "prod", "type" => "push"}
    end

    test "rejects user labels with the keys of automatic labels" do
      monitor = monitor_fixture(:http)

      assert {:error, changeset} = Monitoring.update_monitor(monitor, %{labels: ["host=web1"]})
      assert %{labels: ["host is an automatic label, use another key"]} = errors_on(changeset)

      assert {:error, changeset} =
               Monitoring.update_monitor(monitor, %{labels: ["Type=x", "host", "env"]})

      assert %{labels: ["host and type are automatic labels, use other keys"]} =
               errors_on(changeset)
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

  describe "put_labels/2 and delete_labels/2" do
    test "add, replace and remove labels on many monitors and broadcast the changed ones" do
      a = monitor_fixture(:http, %{labels: %{"env" => "dev", "site" => "oslo"}})
      b = monitor_fixture(:tcp)
      c = monitor_fixture(:http, %{labels: %{"env" => "prod"}})
      untouched = monitor_fixture(:http, %{labels: %{"env" => "dev"}})
      Monitoring.subscribe_monitors()

      assert {:ok, changed} = Monitoring.put_labels([a, b.id, c, -1], ["Env=prod", "legacy"])
      assert ids(changed) == ids([a, b, c])

      assert Monitoring.get_monitor!(a.id).labels == %{
               "env" => "prod",
               "site" => "oslo",
               "legacy" => ""
             }

      assert Monitoring.get_monitor!(b.id).labels == %{"env" => "prod", "legacy" => ""}
      assert Monitoring.get_monitor!(untouched.id).labels == %{"env" => "dev"}

      for %{id: id} <- [a, b, c] do
        assert_receive {:monitor_updated, %Monitor{id: ^id}}
      end

      # Monitors that already have the labels don't change.
      assert {:ok, []} = Monitoring.put_labels([a, b], %{"env" => "prod"})

      assert {:ok, changed} = Monitoring.delete_labels([a, b, untouched], [" ENV", "site"])
      assert ids(changed) == ids([a, b, untouched])
      assert Monitoring.get_monitor!(a.id).labels == %{"legacy" => ""}
      assert Monitoring.get_monitor!(untouched.id).labels == %{}
      assert Monitoring.get_monitor!(c.id).labels == %{"env" => "prod", "legacy" => ""}

      a_id = a.id
      assert_receive {:monitor_updated, %Monitor{id: ^a_id, labels: %{"legacy" => ""}}}
    end

    test "rejects invalid labels" do
      monitor = monitor_fixture()

      assert {:error, changeset} = Monitoring.put_labels([monitor], ["bad key"])
      assert %{labels: [~s(invalid label key "bad key")]} = errors_on(changeset)
      assert Monitoring.get_monitor!(monitor.id).labels == %{}
    end

    test "can't set or remove automatic labels" do
      monitor = monitor_fixture(:http, %{labels: %{"env" => "prod"}})

      assert {:error, changeset} = Monitoring.put_labels([monitor], ["Host=web1", "site=oslo"])
      assert %{labels: ["host is an automatic label, use another key"]} = errors_on(changeset)

      assert {:error, changeset} = Monitoring.delete_labels([monitor], ["env", "type", "HOST"])

      assert %{labels: ["host and type are automatic labels, use other keys"]} =
               errors_on(changeset)

      monitor = Monitoring.get_monitor!(monitor.id)
      assert monitor.labels == %{"env" => "prod"}
      assert %{"type" => "http", "host" => "example.com"} = monitor.all_labels
    end

    test "change all monitors or none" do
      full = for i <- 1..63, into: %{}, do: {"k#{i}", ""}
      ok = monitor_fixture()
      too_many = monitor_fixture(:http, %{name: "Full", labels: full})
      Monitoring.subscribe_monitors()

      assert {:error, changeset} = Monitoring.put_labels([ok, too_many], ["a", "b"])
      assert changeset.data.id == too_many.id
      assert %{labels: ["at most 64 labels are allowed"]} = errors_on(changeset)

      assert Monitoring.get_monitor!(ok.id).labels == %{}
      ok_id = ok.id
      refute_received {:monitor_updated, %Monitor{id: ^ok_id}}
    end
  end

  describe "set_monitors_enabled/2" do
    test "pauses and resumes monitors, broadcasting the changed ones" do
      enabled = monitor_fixture()
      paused = monitor_fixture(:http, %{enabled: false})
      Monitoring.subscribe_monitors()

      assert {:ok, [%Monitor{enabled: false} = changed]} =
               Monitoring.set_monitors_enabled([enabled, paused.id], false)

      assert changed.id == enabled.id
      assert_receive {:monitor_updated, ^changed}
      paused_id = paused.id
      refute_received {:monitor_updated, %Monitor{id: ^paused_id}}

      assert {:ok, resumed} = Monitoring.set_monitors_enabled([enabled, paused], true)
      assert ids(resumed) == ids([enabled, paused])
      assert Monitoring.get_monitor!(enabled.id).enabled
      assert Monitoring.get_monitor!(paused.id).enabled
    end
  end

  describe "delete_monitors/1" do
    test "deletes the monitors with their history and broadcasts" do
      a = monitor_fixture()
      b = monitor_fixture()
      kept = monitor_fixture()
      check_result_fixture(a)
      incident_fixture(b)
      Monitoring.subscribe_monitors()

      assert {:ok, deleted} = Monitoring.delete_monitors([a, b.id, -1])
      assert ids(deleted) == ids([a, b])
      refute Monitoring.get_monitor(a.id)
      refute Monitoring.get_monitor(b.id)
      assert Monitoring.get_monitor(kept.id)
      assert Monitoring.latest_results(a) == []
      assert Monitoring.list_incidents(b) == []

      for %{id: id} <- [a, b] do
        assert_receive {:monitor_deleted, %Monitor{id: ^id}}
      end

      assert {:ok, []} = Monitoring.delete_monitors([])
    end
  end

  describe "change_monitor/2" do
    test "returns a changeset" do
      assert %Ecto.Changeset{} = Monitoring.change_monitor(monitor_fixture())
      assert %Ecto.Changeset{valid?: false} = Monitoring.change_monitor(%Monitor{})
    end
  end

  describe "clone_monitor/1" do
    test "copies the configuration under a new name" do
      source =
        monitor_fixture(:tcp, %{
          name: "db1",
          enabled: false,
          interval_seconds: 120,
          retry_interval_seconds: 30,
          max_retries: 2,
          timeout_ms: 5_000,
          description: "Primary",
          labels: %{"env" => "prod", "instance" => "db1"},
          settings: %{host: "db1.example.com", port: 5432}
        })

      clone = Monitoring.clone_monitor(source)

      assert %Monitor{
               id: nil,
               name: "db1 (copy)",
               type: :tcp,
               enabled: false,
               interval_seconds: 120,
               retry_interval_seconds: 30,
               max_retries: 2,
               timeout_ms: 5_000,
               description: "Primary",
               labels: %{"env" => "prod", "instance" => "db1"},
               settings: %Settings{host: "db1.example.com", port: 5432}
             } = clone

      assert {:ok, saved} = Repo.insert(Monitoring.change_monitor(clone))
      assert saved.id != source.id
    end

    test "keeps long names within the limit" do
      source = monitor_fixture(:http, %{name: String.duplicate("a", 255)})
      clone = Monitoring.clone_monitor(source)

      assert String.length(clone.name) == 255
      assert String.ends_with?(clone.name, "a (copy)")
    end

    test "doesn't copy secrets, a blank value doesn't keep the source's" do
      source = monitor_fixture(:postgres, %{secrets: %{password: "source-s3cret"}})
      clone = Monitoring.clone_monitor(source)

      assert clone.secrets == %{}

      changeset = Monitoring.change_monitor(clone, %{"secrets" => %{"password" => ""}})
      assert Ecto.Changeset.get_field(changeset, :secrets) == %{}

      {:ok, saved} = Repo.insert(changeset)
      assert Monitoring.get_monitor!(saved.id).secrets == %{}
      assert Monitoring.get_monitor!(source.id).secrets == %{"password" => "source-s3cret"}
    end

    test "push monitors get a new push token" do
      source = monitor_fixture(:push)
      clone = Monitoring.clone_monitor(source)

      assert clone.settings.push_token != source.settings.push_token
      assert clone.settings.push_grace_seconds == source.settings.push_grace_seconds
      assert {:ok, _saved} = Repo.insert(Monitoring.change_monitor(clone))
    end
  end

  describe "dependencies" do
    test "a monitor can have a parent, deleting the parent detaches it" do
      parent = monitor_fixture(:ping)
      child = monitor_fixture(:http, %{parent_id: parent.id})

      assert child.parent_id == parent.id
      assert [%Monitor{id: id}] = Monitoring.list_children(parent)
      assert id == child.id

      {:ok, _} = Monitoring.delete_monitor(parent)
      assert Monitoring.get_monitor!(child.id).parent_id == nil
    end

    test "the parent can be changed and removed" do
      [a, b] = [monitor_fixture(:ping), monitor_fixture(:ping)]
      child = monitor_fixture(:http, %{parent_id: a.id})

      assert {:ok, %{parent_id: parent_id}} = Monitoring.update_monitor(child, %{parent_id: b.id})
      assert parent_id == b.id

      assert {:ok, %{parent_id: nil}} =
               Monitoring.update_monitor(child, %{"parent_id" => ""})
    end

    test "rejects an unknown parent" do
      assert {:error, changeset} =
               Monitoring.create_monitor(valid_monitor_attrs(:http, %{parent_id: -1}))

      assert "does not exist" in errors_on(changeset).parent_id
    end

    test "a monitor can't be its own parent" do
      monitor = monitor_fixture(:http)

      assert {:error, changeset} = Monitoring.update_monitor(monitor, %{parent_id: monitor.id})
      assert "can't be the monitor itself" in errors_on(changeset).parent_id
    end

    test "rejects direct and indirect cycles" do
      a = monitor_fixture(:ping)
      b = monitor_fixture(:tcp, %{parent_id: a.id})
      c = monitor_fixture(:http, %{parent_id: b.id})

      assert {:error, changeset} = Monitoring.update_monitor(a, %{parent_id: b.id})
      assert "would create a dependency cycle" in errors_on(changeset).parent_id

      assert {:error, changeset} = Monitoring.update_monitor(a, %{parent_id: c.id})
      assert "would create a dependency cycle" in errors_on(changeset).parent_id
      assert Monitoring.get_monitor!(a.id).parent_id == nil

      # Not a cycle: c moves up next to b.
      assert {:ok, %{parent_id: parent_id}} = Monitoring.update_monitor(c, %{parent_id: a.id})
      assert parent_id == a.id
    end

    test "ancestor_ids/1 and descendant_ids/1 follow the chain, nearest first" do
      a = monitor_fixture(:ping)
      b = monitor_fixture(:tcp, %{parent_id: a.id})
      c = monitor_fixture(:http, %{parent_id: b.id})
      d = monitor_fixture(:http, %{parent_id: b.id})

      assert Monitoring.ancestor_ids(c) == [b.id, a.id]
      assert Monitoring.ancestor_ids(c.id) == [b.id, a.id]
      assert Monitoring.ancestor_ids(a) == []
      assert Monitoring.ancestor_ids(nil) == []

      assert Monitoring.descendant_ids(a) == [b.id | Enum.sort([c.id, d.id])]
      assert Monitoring.descendant_ids(c) == []
    end

    test "suggest_parent/1 suggests the ping or TCP monitor of the same host" do
      ping = monitor_fixture(:ping, %{name: "web1 ping", settings: %{host: "web1.example.com"}})

      tcp =
        monitor_fixture(:tcp, %{name: "web1 ssh", settings: %{host: "web1.example.com", port: 22}})

      _other = monitor_fixture(:ping, %{settings: %{host: "web2.example.com"}})

      http = monitor_fixture(:http, %{settings: %{url: "https://WEB1.example.com/health"}})
      assert Monitoring.suggest_parent(http).id == ping.id
      # TCP monitors only get ping monitors, ping monitors nothing.
      assert Monitoring.suggest_parent(tcp).id == ping.id
      assert Monitoring.suggest_parent(ping) == nil

      # Unsaved monitors, e.g. while filling in the form.
      unsaved =
        %Monitor{}
        |> Monitoring.change_monitor(
          valid_monitor_attrs(:cert, %{settings: %{host: "web1.example.com"}})
        )
        |> Ecto.Changeset.apply_changes()

      assert Monitoring.suggest_parent(unsaved).id == ping.id

      # Without a ping monitor the TCP monitor is suggested.
      {:ok, _} = Monitoring.delete_monitor(ping)
      assert Monitoring.suggest_parent(http).id == tcp.id

      assert Monitoring.suggest_parent(monitor_fixture(:push)) == nil

      assert Monitoring.suggest_parent(
               monitor_fixture(:http, %{settings: %{url: "https://nope.example.com"}})
             ) == nil
    end

    test "suggest_parent/1 doesn't suggest a monitor that depends on the monitor" do
      tcp = monitor_fixture(:tcp, %{settings: %{host: "db1.example.com", port: 5432}})
      _ping = monitor_fixture(:ping, %{settings: %{host: "db1.example.com"}, parent_id: tcp.id})

      assert Monitoring.suggest_parent(tcp) == nil
    end

    test "clones keep the parent" do
      parent = monitor_fixture(:ping)
      source = monitor_fixture(:http, %{parent_id: parent.id})

      assert Monitoring.clone_monitor(source).parent_id == parent.id
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
