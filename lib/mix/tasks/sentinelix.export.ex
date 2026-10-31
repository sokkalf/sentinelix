defmodule Mix.Tasks.Sentinelix.Export do
  @shortdoc "Exports monitors as YAML"

  @moduledoc """
  Exports monitors as YAML (format: `Sentinelix.Monitoring.Export`), to
  keep them in git or move them to another instance.

      $ mix sentinelix.export > monitors.yaml
      $ mix sentinelix.export --selector "env=prod" --output prod.yaml
      $ mix sentinelix.export --push-tokens --output monitors.yaml

  Options:

    * `--selector SELECTOR` – only monitors matching the selector (label and
      name terms, see `Sentinelix.Monitoring.Selector`).
    * `--output FILE` – write to `FILE` instead of standard output.
    * `--push-tokens` – include the push tokens of push monitors. They are
      credentials, so they're left out by default.

  Secrets (e.g. PostgreSQL passwords) are never exported. In a release use
  `bin/export_monitors` with the same options.
  """
  use Mix.Task

  alias Sentinelix.Monitoring.CLI

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(Sentinelix.Repo, fn _repo -> CLI.export(args) end)

    case result do
      {:ok, yaml, nil} ->
        IO.write(yaml)

      {:ok, yaml, path} ->
        File.write!(path, yaml)
        Mix.shell().info("Exported monitors to #{path}")

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
