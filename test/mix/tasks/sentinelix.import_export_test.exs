defmodule Mix.Tasks.Sentinelix.ImportExportTest do
  use Sentinelix.DataCase, async: false

  import ExUnit.CaptureIO
  import Sentinelix.MonitoringFixtures

  alias Mix.Tasks.Sentinelix.{Export, Import}
  alias Sentinelix.{Monitoring, Repo}
  alias Sentinelix.Monitoring.Monitor

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "exports to standard output or a file and imports it back", %{tmp_dir: dir} do
    monitor_fixture(:ping, %{name: "Router", labels: %{"env" => "prod"}})
    monitor_fixture(:ping, %{name: "Other"})

    yaml = capture_io(fn -> Export.run(["--selector", "env=prod"]) end)
    assert yaml =~ "name: Router"
    refute yaml =~ "name: Other"

    path = Path.join(dir, "monitors.yaml")
    Export.run(["--output", path])
    assert_received {:mix_shell, :info, ["Exported monitors to " <> ^path]}
    assert File.read!(path) =~ "name: Other"

    Repo.delete_all(Monitor)

    Import.run([path, "--dry-run"])
    assert_received {:mix_shell, :info, [report]}
    assert report =~ "  create  Router"
    assert report =~ "Dry run, nothing written: 2 to create, 0 to update, 0 unchanged."
    assert Monitoring.list_monitors() == []

    Import.run([path])
    assert_received {:mix_shell, :info, [report]}
    assert report =~ "Created 2, updated 0, 0 unchanged."
    assert length(Monitoring.list_monitors()) == 2
  end

  test "reports missing monitors and changes", %{tmp_dir: dir} do
    monitor_fixture(:ping, %{name: "Router", settings: %{host: "10.0.0.1"}})
    monitor_fixture(:ping, %{name: "Leftover"})

    path = Path.join(dir, "monitors.yaml")

    File.write!(path, """
    version: 1
    monitors:
      - {name: Router, type: ping, interval_seconds: 300, settings: {host: 10.0.0.1}}
    """)

    Import.run([path, "--report-missing"])
    assert_received {:mix_shell, :info, [report]}

    assert report ==
             Enum.join(
               [
                 "  update  Router (interval_seconds)",
                 "  missing Leftover (not in the file, left alone)",
                 "Created 0, updated 1, 0 unchanged."
               ],
               "\n"
             )
  end

  test "fails with every error and changes nothing", %{tmp_dir: dir} do
    path = Path.join(dir, "broken.yaml")

    File.write!(path, """
    version: 1
    monitors:
      - {name: A, type: ping}
      - {name: B, type: http, settings: {url: nope}}
    """)

    error = assert_raise Mix.Error, fn -> Import.run([path]) end

    assert error.message == """
           Nothing was imported:
             monitor 1 "A": settings.host can't be blank
             monitor 2 "B": settings.url must be a valid http:// or https:// URL\
           """

    assert Monitoring.list_monitors() == []

    assert_raise Mix.Error, ~r/Could not read/, fn -> Import.run([Path.join(dir, "nope")]) end
    assert_raise Mix.Error, ~r/Expected one file/, fn -> Import.run([]) end
    assert_raise Mix.Error, ~r/Invalid options: --nope/, fn -> Import.run([path, "--nope"]) end

    assert_raise Mix.Error, ~r/Invalid selector/, fn ->
      Export.run(["--selector", "status=up"])
    end
  end
end
