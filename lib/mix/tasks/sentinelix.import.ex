defmodule Mix.Tasks.Sentinelix.Import do
  @shortdoc "Imports monitors from YAML"

  @moduledoc """
  Imports monitors from a YAML file in the format of
  `Sentinelix.Monitoring.Export` (`-` reads standard input). See
  `Sentinelix.Monitoring.Import` for how monitors are matched (by name) and
  what is changed.

      $ mix sentinelix.import monitors.yaml --dry-run
      $ mix sentinelix.import monitors.yaml
      $ mix sentinelix.import prod.yaml --report-missing --selector "env=prod"

  Options:

    * `--dry-run` – check the file and show what would change, without
      writing anything.
    * `--report-missing` – also list the monitors that aren't in the file.
      They are left alone.
    * `--selector SELECTOR` – with `--report-missing`, only report monitors
      matching the selector (e.g. the one the file was exported with).

  The import is all or nothing: any error (each is reported with its
  monitor and field) leaves the database unchanged, and the task fails.

  The task runs outside the server, so a server that is already running
  picks the changes up when it restarts. In a release, use
  `bin/import_monitors` with the same arguments: it runs inside the running
  server, which (re)starts the changed monitors right away.
  """
  use Mix.Task

  alias Sentinelix.Monitoring.CLI

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(Sentinelix.Repo, fn _repo ->
        # The context broadcasts monitor events.
        ensure_pubsub()
        CLI.import(args)
      end)

    case result do
      {:ok, report} -> Mix.shell().info(report)
      {:error, report} -> Mix.raise(report)
    end
  end

  defp ensure_pubsub do
    if Process.whereis(Sentinelix.PubSub) == nil do
      {:ok, _pid} = Phoenix.PubSub.Supervisor.start_link(name: Sentinelix.PubSub)
    end
  end
end
