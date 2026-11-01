defmodule Sentinelix.Monitoring.ImportExportTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures
  import Sentinelix.NotificationsFixtures

  alias Sentinelix.{Monitoring, Notifications, Repo}
  alias Sentinelix.Monitoring.{Export, Import, Monitor}
  alias Sentinelix.Monitoring.Import.{Change, Error, Result}
  alias Sentinelix.Monitoring.Settings.Assertion

  defp export!(opts \\ []) do
    {:ok, yaml} = Export.export(opts)
    yaml
  end

  defp import!(yaml, opts \\ []) do
    case Import.run(yaml, opts) do
      {:ok, result} -> result
      {:error, errors} -> flunk("import failed: #{Enum.map_join(errors, "\n", &Error.format/1)}")
    end
  end

  defp import_errors(yaml, opts \\ []) do
    assert {:error, errors} = Import.run(yaml, opts)
    Enum.map(errors, &Error.format/1)
  end

  defp actions(%Result{changes: changes}),
    do: Map.new(changes, fn %Change{} = change -> {change.name, change.action} end)

  defp delete_all_monitors, do: Repo.delete_all(Monitor)

  # A setup using every type, labels, channels, parents and secrets.
  defp setup_monitors(_context) do
    email = channel_fixture(:email, %{name: "Ops email"})
    slack = channel_fixture(:slack, %{name: "Slack"})

    router = monitor_fixture(:ping, %{name: "Router", settings: %{host: "10.0.0.1"}})

    api =
      monitor_fixture(:http, %{
        name: "Shop API",
        description: "The public API\nwith two lines",
        interval_seconds: 30,
        retry_interval_seconds: 20,
        max_retries: 2,
        timeout_ms: 10_000,
        labels: %{"env" => "prod", "legacy" => ""},
        parent_id: router.id,
        settings: %{
          url: "https://shop.example.com/health",
          method: "POST",
          headers: %{"Authorization" => "Bearer header-token"},
          body: ~s({"ping": true}),
          accepted_status_codes: ["200", "300-399"],
          assertions: [
            %{source: "json", path: "status", comparison: "equals", value: "ok"},
            %{source: "header", path: "x-version", comparison: "exists"},
            %{source: "body", comparison: "regex", value: "^\\s*\\{", case_sensitive: false}
          ]
        }
      })

    db =
      monitor_fixture(:postgres, %{
        name: "Database",
        enabled: false,
        secrets: %{"password" => "postgres-secret-pw"},
        settings: %{
          host: "db.example.com",
          database: "app",
          username: "monitor",
          query: "SELECT count(*)\nFROM jobs\nWHERE failed",
          expected_value: "0"
        }
      })

    push = monitor_fixture(:push, %{name: "Backup job"})

    others =
      for type <- [:http, :tcp, :dns, :cert],
          do: monitor_fixture(type, %{name: "Other #{type}"})

    Notifications.put_monitor_channels(api, [email, slack])
    Notifications.put_monitor_channels(db, [email])

    %{router: router, api: api, db: db, push: push, others: others, email: email, slack: slack}
  end

  describe "export" do
    setup :setup_monitors

    test "writes the documented format", %{api: api} do
      yaml = export!(selector: "name=\"Shop API\"")
      assert {:ok, _} = Sentinelix.YAML.decode(yaml)

      assert yaml == """
             # Sentinelix monitors
             version: 1
             monitors:
               - name: Shop API
                 type: http
                 enabled: true
                 interval_seconds: 30
                 retry_interval_seconds: 20
                 max_retries: 2
                 timeout_ms: 10000
                 description: |-
                   The public API
                   with two lines
                 parent: Router
                 labels:
                   env: prod
                   legacy: ""
                 channels:
                   - Ops email
                   - Slack
                 settings:
                   url: https://shop.example.com/health
                   method: POST
                   headers:
                     Authorization: Bearer header-token
                   body: "{\\"ping\\": true}"
                   accepted_status_codes:
                     - "200"
                     - "300-399"
                   follow_redirects: true
                   max_redirects: 10
                   verify_tls: true
                   assertions:
                     - source: json
                       path: status
                       comparison: equals
                       value: ok
                     - source: header
                       path: x-version
                       comparison: exists
                     - source: body
                       comparison: regex
                       value: "^\\\\s*\\\\{"
                       case_sensitive: false
             """

      assert api.auto_labels != %{}
      refute yaml =~ "auto_labels"
    end

    test "never contains secrets or push tokens", %{db: db, push: push} do
      yaml = export!()

      refute yaml =~ "postgres-secret-pw"
      refute yaml =~ "secrets"
      refute yaml =~ "password"
      refute yaml =~ push.settings.push_token
      refute yaml =~ "push_token"
      assert Monitor.secret(db, "password") == "postgres-secret-pw"
    end

    test "includes push tokens when asked", %{push: push} do
      {:ok, %{"monitors" => monitors}} = Sentinelix.YAML.decode(export!(push_tokens: true))
      backup = Enum.find(monitors, &(&1["name"] == "Backup job"))
      assert backup["settings"]["push_token"] == push.settings.push_token
    end

    test "exports the monitors matching a selector, ordered by name" do
      yaml = export!(selector: "type in (ping,tcp)")
      {:ok, %{"monitors" => monitors}} = Sentinelix.YAML.decode(yaml)
      assert Enum.map(monitors, & &1["name"]) == ["Other tcp", "Router"]
    end

    test "rejects invalid selectors and status terms" do
      assert {:error, %Monitoring.Selector.Error{}} = Export.export(selector: "env=")
      assert {:error, %Monitoring.Selector.Error{}} = Export.export(selector: "status=down")
    end

    test "is stable" do
      assert export!() == export!()
    end
  end

  describe "round trip" do
    setup :setup_monitors

    test "export, import into an empty database and export again gives the same file" do
      yaml = export!(push_tokens: true)
      delete_all_monitors()
      assert Monitoring.list_monitors() == []

      result = import!(yaml)
      assert Enum.all?(result.changes, &(&1.action == :create))
      assert length(result.changes) == 8

      assert export!(push_tokens: true) == yaml

      # And importing it again changes nothing.
      assert yaml |> import!() |> Result.counts() == %{create: 0, update: 0, unchanged: 8}
    end

    test "without push tokens, created push monitors get a new one", %{push: push} do
      yaml = export!()
      delete_all_monitors()
      import!(yaml)

      [new] = Monitoring.list_monitors(type: :push)
      assert is_binary(new.settings.push_token)
      assert new.settings.push_token != push.settings.push_token
      assert export!() == yaml
    end

    test "the import of an unchanged setup is a no-op and keeps secrets and tokens",
         %{db: db, push: push} do
      result = import!(export!())
      assert Result.counts(result) == %{create: 0, update: 0, unchanged: 8}

      assert Monitor.secret(Monitoring.get_monitor!(db.id), "password") == "postgres-secret-pw"
      assert Monitoring.get_monitor!(push.id).settings.push_token == push.settings.push_token
    end
  end

  describe "import" do
    setup :setup_monitors

    test "a dry run reports the changes without writing", %{api: api, router: router} do
      yaml =
        export!()
        |> String.replace("interval_seconds: 30", "interval_seconds: 45")
        |> String.replace("https://shop.example.com/health", "https://shop.example.com/up")
        |> String.replace("    channels:\n      - Ops email\n      - Slack\n", "")
        |> String.replace(
          "monitors:\n",
          "monitors:\n  - name: New one\n    type: ping\n    parent: Router\n    settings:\n      host: 10.0.0.2\n"
        )

      before = Repo.aggregate(Monitor, :count)
      assert %Result{dry_run: true} = result = import!(yaml, dry_run: true)
      assert Repo.aggregate(Monitor, :count) == before

      assert actions(result)["New one"] == :create
      assert actions(result)["Router"] == :unchanged

      assert %Change{action: :update, fields: fields} =
               Enum.find(result.changes, &(&1.name == "Shop API"))

      assert fields == ["interval_seconds", "settings.url", "channels"]
      assert Monitoring.get_monitor!(api.id).interval_seconds == 30
      assert Monitoring.get_monitor!(router.id)
      assert result.missing == nil
    end

    test "imports changes, creates monitors and sets parents and channels",
         %{api: api, router: router, email: email} do
      yaml = """
      version: 1
      monitors:
        - name: Shop API
          type: http
          interval_seconds: 120
          parent: Edge
          channels: [Ops email]
          labels: {env: staging}
          settings:
            url: https://shop.example.com/health
        - name: Edge
          type: ping
          parent: Router
          settings: {host: 10.0.0.9}
      """

      result = import!(yaml)
      assert actions(result) == %{"Shop API" => :update, "Edge" => :create}

      edge = Enum.find(Monitoring.list_monitors(), &(&1.name == "Edge"))
      api = Monitoring.get_monitor!(api.id)

      assert edge.parent_id == router.id
      assert api.parent_id == edge.id
      assert api.interval_seconds == 120
      # Left out: back to the defaults.
      assert api.retry_interval_seconds == 60
      assert api.description == nil
      assert api.settings.method == "GET"
      assert api.settings.headers == %{}
      assert api.labels == %{"env" => "staging"}
      assert Notifications.monitor_channel_ids(api) == [email.id]
      # No default channels for created monitors, only those in the file.
      assert Notifications.monitor_channel_ids(edge) == []
    end

    test "created monitors get exactly their channels, not the defaults" do
      channel_fixture(:webhook, %{name: "Default", default: true})

      import!("""
      version: 1
      monitors:
        - {name: Fresh, type: ping, settings: {host: 10.0.0.5}}
      """)

      [fresh] = Monitoring.list_monitors(selector: "name=Fresh")
      assert Notifications.monitor_channel_ids(fresh) == []
    end

    test "starts and restarts workers through monitor events after the commit", %{api: api} do
      Monitoring.subscribe_monitors()

      import!("""
      version: 1
      monitors:
        - {name: Shop API, type: http, settings: {url: "https://shop.example.com/x"}, parent: Router}
        - {name: Fresh, type: ping, settings: {host: 10.0.0.5}}
      """)

      api_id = api.id
      assert_received {:monitor_updated, %Monitor{id: ^api_id} = updated}
      assert updated.settings.url == "https://shop.example.com/x"
      assert_received {:monitor_created, %Monitor{name: "Fresh"}}
      # One event per monitor.
      refute_received {:monitor_updated, %Monitor{id: ^api_id}}
      refute_received {:monitor_updated, %Monitor{name: "Fresh"}}
    end

    test "an unchanged monitor sends no event" do
      yaml = export!()
      ids = MapSet.new(Monitoring.list_monitors(), & &1.id)
      Monitoring.subscribe_monitors()
      import!(yaml)

      {:messages, messages} = Process.info(self(), :messages)

      refute Enum.any?(messages, fn
               {:monitor_updated, %Monitor{id: id}} -> MapSet.member?(ids, id)
               _other -> false
             end)
    end

    test "keeps the secrets of updated monitors and creates monitors without secrets",
         %{db: db} do
      import!("""
      version: 1
      monitors:
        - name: Database
          type: postgres
          settings: {host: db2.example.com, database: app, username: monitor}
        - name: Database 2
          type: postgres
          settings: {host: db3.example.com, database: app, username: monitor}
      """)

      db = Monitoring.get_monitor!(db.id)
      assert db.settings.host == "db2.example.com"
      assert Monitor.secret(db, "password") == "postgres-secret-pw"

      [db2] = Monitoring.list_monitors(selector: ~s(name="Database 2"))
      assert db2.secrets == %{}
    end

    test "rejects secrets in the file" do
      assert import_errors("""
             version: 1
             monitors:
               - name: Database
                 type: postgres
                 secrets: {password: x}
                 settings: {host: db.example.com, database: app, username: monitor}
             """) == [~s(monitor 1 "Database": secrets can't be imported, set secrets in the UI)]
    end

    test "uses push tokens from the file and keeps them otherwise", %{push: push} do
      token = String.duplicate("t", 32)

      import!("""
      version: 1
      monitors:
        - {name: Backup job, type: push, settings: {push_grace_seconds: 60}}
      """)

      assert Monitoring.get_monitor!(push.id).settings.push_token == push.settings.push_token

      import!("""
      version: 1
      monitors:
        - {name: Backup job, type: push, settings: {push_token: #{token}}}
      """)

      assert Monitoring.get_monitor!(push.id).settings.push_token == token
    end

    test "rejects push tokens that are already in use", %{push: push} do
      assert import_errors("""
             version: 1
             monitors:
               - {name: Another job, type: push, settings: {push_token: #{push.settings.push_token}}}
             """) == [~s(monitor 1 "Another job": settings.push_token is already in use)]
    end

    test "reports missing monitors, optionally within a selector" do
      yaml = """
      version: 1
      monitors:
        - {name: Router, type: ping, settings: {host: 10.0.0.1}}
      """

      result = import!(yaml, dry_run: true, missing: :report)
      assert "Shop API" in result.missing
      refute "Router" in result.missing
      assert length(result.missing) == 7

      result = import!(yaml, missing: :report, selector: "type=ping")
      assert result.missing == []

      result = import!(yaml, missing: :report, selector: "type=http")
      assert result.missing == ["Other http", "Shop API"]

      # Never deleted.
      assert Repo.aggregate(Monitor, :count) == 8
    end

    test "is all or nothing", %{api: api} do
      yaml = """
      version: 1
      monitors:
        - {name: Shop API, type: http, interval_seconds: 300, settings: {url: "https://x.example.com"}}
        - {name: Broken, type: http, settings: {url: "not a url"}}
      """

      assert [~s(monitor 2 "Broken": settings.url must be a valid http:// or https:// URL)] =
               import_errors(yaml)

      assert Monitoring.get_monitor!(api.id).interval_seconds == 30
      assert Monitoring.list_monitors(selector: "name=Broken") == []
    end

    test "names the monitor and the field in errors" do
      yaml = """
      version: 1
      monitors:
        - name: A
          type: http
          interval_seconds: 5
          labels: {type: x}
          settings: {url: "https://a.example.com", hostname: x}
        - {name: B, type: nope}
        - {type: ping}
        - {name: C, type: ping, settings: {host: "-bad"}, channels: [Nope], parent: Nobody}
        - {name: C, type: ping, settings: {host: 10.0.0.1}}
        - just a string
      """

      assert import_errors(yaml) == [
               ~s(monitor 1 "A": settings.hostname is not a setting of http monitors),
               ~s(monitor 2 "B": type must be one of http, tcp, ping, dns, cert, push, postgres),
               ~s(monitor 3: name must be a non-empty string),
               # The valid monitors are checked too.
               ~s(monitor 4 "C": channels "Nope" doesn't exist),
               ~s(monitor 5 "C": name is used by another monitor in the file),
               "monitor 6: must be a mapping with name, type, ..."
             ]

      yaml = """
      version: 1
      monitors:
        - name: A
          type: http
          interval_seconds: 5
          labels: {type: x}
          settings: {url: "https://a.example.com"}
        - {name: C, type: ping, settings: {host: "-bad"}, channels: [Nope], parent: Nobody}
      """

      assert import_errors(yaml) == [
               ~s(monitor 1 "A": interval_seconds must be greater than or equal to 20),
               ~s(monitor 1 "A": labels type is an automatic label, use another key),
               ~s(monitor 1 "A": timeout_ms must not be longer than the check interval),
               ~s(monitor 2 "C": channels "Nope" doesn't exist)
             ]

      assert import_errors("""
             version: 1
             monitors:
               - {name: C, type: ping, settings: {host: "-bad"}, parent: Nobody}
             """) == [~s(monitor 1 "C": parent "Nobody" doesn't exist)]

      assert import_errors("""
             version: 1
             monitors:
               - {name: C, type: ping, settings: {host: "-bad"}}
             """) == [~s(monitor 1 "C": settings.host must be a valid hostname or IP address)]
    end

    test "imports assertions and names the failing one in errors" do
      yaml = """
      version: 1
      monitors:
        - name: Health
          type: http
          settings:
            url: https://health.example.com
            assertions:
              - {source: json, path: queue.depth, comparison: "<", value: "100"}
              - {source: body, comparison: regex, value: "("}
              - {source: header, comparison: exists}
      """

      assert import_errors(yaml) == [
               ~s(monitor 1 "Health": settings.assertions.1.value must be a valid regular expression),
               ~s(monitor 1 "Health": settings.assertions.2.path can't be blank)
             ]

      yaml = String.replace(yaml, ~s(value: "("}), ~s(value: "^ok"}))
      yaml = String.replace(yaml, "{source: header, ", "{source: header, path: etag, ")
      import!(yaml)

      [monitor] = Monitoring.list_monitors(selector: "name=Health")

      assert [
               %{source: "json", path: "queue.depth", comparison: "<", value: "100"},
               %{source: "body", path: nil, comparison: "regex", value: "^ok"},
               %{source: "header", path: "etag", comparison: "exists", value: nil}
             ] = monitor.settings.assertions

      assert yaml |> import!() |> Result.counts() == %{create: 0, update: 0, unchanged: 1}
    end

    test "imports keyword monitors of older files as http monitors with an assertion" do
      yaml = """
      version: 1
      monitors:
        - name: Homepage
          type: keyword
          settings:
            url: https://www.example.com
            keyword: Welcome
            case_sensitive: false
        - name: Status API
          type: keyword
          settings:
            url: https://api.example.com/status
            keyword: DOWN
            json_path: data.status
            invert_keyword: true
        - name: Broken
          type: keyword
          settings: {url: "https://x.example.com", json_path: "a..b"}
      """

      assert import_errors(yaml) == [
               ~s(monitor 3 "Broken": settings.assertions.0.path must be a dot-separated path like "data.items.0.status"),
               ~s(monitor 3 "Broken": settings.assertions.0.value can't be blank)
             ]

      yaml |> String.split("  - name: Broken") |> hd() |> import!()

      [homepage] = Monitoring.list_monitors(selector: "name=Homepage")
      [api] = Monitoring.list_monitors(selector: ~s(name="Status API"))

      assert homepage.type == :http
      assert homepage.auto_labels["type"] == "http"
      assert homepage.settings.url == "https://www.example.com"

      assert [
               %Assertion{
                 source: "body",
                 path: nil,
                 comparison: "contains",
                 value: "Welcome",
                 case_sensitive: false
               }
             ] = homepage.settings.assertions

      assert [
               %Assertion{
                 source: "json",
                 path: "data.status",
                 comparison: "not_equals",
                 value: "DOWN",
                 case_sensitive: true
               }
             ] = api.settings.assertions
    end

    test "checks the file structure and version" do
      assert import_errors("monitors: []") == [
               "version is missing (the format version, 1)"
             ]

      assert import_errors("version: 2\nmonitors: []") == [
               "version 2 is not supported (expected 1)"
             ]

      assert import_errors("version: 1\nmonitor: []") == ["unknown key monitor"]
      assert import_errors("- a") == ["expected a mapping with version and monitors"]
      assert [message] = import_errors("version: 1\nmonitors: [!evil x]")
      assert message =~ "unrecognized"
      assert import!("version: 1\nmonitors: []").changes == []
    end

    test "rejects ambiguous names" do
      monitor_fixture(:ping, %{name: "Twin"})
      monitor_fixture(:ping, %{name: "Twin"})

      assert import_errors("""
             version: 1
             monitors:
               - {name: Twin, type: ping, settings: {host: 10.0.0.1}}
             """) == [
               ~s(monitor 1 "Twin": name matches 2 existing monitors, rename them so names are unique)
             ]
    end

    test "rejects dependency cycles, also with existing monitors", %{router: router} do
      assert import_errors("""
             version: 1
             monitors:
               - {name: A, type: ping, parent: B, settings: {host: 10.0.0.1}}
               - {name: B, type: ping, parent: A, settings: {host: 10.0.0.2}}
             """) == [
               ~s(monitor 1 "A": parent would create a dependency cycle),
               ~s(monitor 2 "B": parent would create a dependency cycle)
             ]

      # Shop API depends on Router, which isn't in the file.
      assert [~s(monitor 1 "Router": parent would create a dependency cycle)] =
               import_errors("""
               version: 1
               monitors:
                 - {name: Router, type: ping, parent: Shop API, settings: {host: 10.0.0.1}}
               """)

      assert Monitoring.get_monitor!(router.id).parent_id == nil
    end

    test "reverses a dependency without a transient cycle", %{api: api, router: router} do
      import!("""
      version: 1
      monitors:
        - {name: Router, type: ping, parent: Shop API, settings: {host: 10.0.0.1}}
        - {name: Shop API, type: http, settings: {url: "https://shop.example.com/health"}}
      """)

      assert Monitoring.get_monitor!(api.id).parent_id == nil
      assert Monitoring.get_monitor!(router.id).parent_id == api.id
    end
  end
end
