defmodule Sentinelix.Monitoring.CLI do
  @moduledoc """
  The command line side of the monitor import/export, shared by the mix
  tasks (`mix sentinelix.export`, `mix sentinelix.import`) and the release
  commands (`bin/export_monitors`, `bin/import_monitors`, see
  `Sentinelix.Release`).

  Export options: `--selector SELECTOR`, `--push-tokens`, `--output FILE`
  (default: standard output).

  Import: `FILE` (`-` for standard input) and the options `--dry-run`,
  `--report-missing` and `--selector SELECTOR` (limits the report of
  missing monitors).

  The functions expect a started repo; they return the text to show instead
  of printing it.
  """

  alias Sentinelix.Monitoring.{Export, Import}
  alias Sentinelix.Monitoring.Import.{Error, Result}

  @export_switches [selector: :string, output: :string, push_tokens: :boolean]
  @import_switches [dry_run: :boolean, report_missing: :boolean, selector: :string]

  @doc """
  Exports monitors as described by the command line arguments. Returns the
  YAML and the file to write it to (`nil` for standard output), or an
  error message.
  """
  @spec export([String.t()]) :: {:ok, String.t(), Path.t() | nil} | {:error, String.t()}
  def export(argv) do
    case parse(argv, @export_switches) do
      {:ok, opts, []} -> export_with(opts)
      {:ok, _opts, args} -> {:error, "Unexpected arguments: #{Enum.join(args, " ")}"}
      error -> error
    end
  end

  defp export_with(opts) do
    case Export.export(selector: opts[:selector], push_tokens: opts[:push_tokens] || false) do
      {:ok, yaml} -> {:ok, yaml, opts[:output]}
      {:error, error} -> {:error, "Invalid selector: " <> Exception.message(error)}
    end
  end

  @doc """
  Imports (or with `--dry-run` checks) the file named by the command line
  arguments, relative to `cwd`. Returns a report of what changed, or of the
  errors found (then nothing changed).
  """
  @spec import([String.t()], Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def import(argv, cwd \\ File.cwd!()) do
    with {:ok, opts, [file]} <- parse(argv, @import_switches),
         {:ok, yaml} <- read(file, cwd) do
      import_opts = [
        dry_run: opts[:dry_run] || false,
        missing: if(opts[:report_missing], do: :report, else: :ignore),
        selector: opts[:selector]
      ]

      case Import.run(yaml, import_opts) do
        {:ok, result} -> {:ok, report(result)}
        {:error, errors} -> {:error, errors_report(errors)}
      end
    else
      {:ok, _opts, _args} -> {:error, "Expected one file to import (or - for standard input)"}
      error -> error
    end
  end

  defp parse(argv, switches) do
    case OptionParser.parse(argv, strict: switches) do
      {opts, args, []} ->
        {:ok, opts, args}

      {_opts, _args, invalid} ->
        {:error, "Invalid options: " <> Enum.map_join(invalid, ", ", &elem(&1, 0))}
    end
  end

  defp read("-", _cwd) do
    case IO.read(:stdio, :eof) do
      data when is_binary(data) -> {:ok, data}
      _eof_or_error -> {:ok, ""}
    end
  end

  defp read(file, cwd) do
    path = Path.expand(file, cwd)

    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "Could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  A report of an import or dry run: a line per created or updated monitor
  (with the changed fields), the missing monitors if they were asked for,
  and a summary.
  """
  @spec report(Result.t()) :: String.t()
  def report(%Result{} = result) do
    counts = Result.counts(result)

    changes =
      for change <- result.changes, change.action != :unchanged do
        case change.action do
          :create -> "  create  #{change.name}"
          :update -> "  update  #{change.name} (#{Enum.join(change.fields, ", ")})"
        end
      end

    missing =
      for name <- result.missing || [],
          do: "  missing #{name} (not in the file, left alone)"

    summary =
      if result.dry_run,
        do:
          "Dry run, nothing written: #{counts.create} to create, #{counts.update} to update, " <>
            "#{counts.unchanged} unchanged.",
        else: "Created #{counts.create}, updated #{counts.update}, #{counts.unchanged} unchanged."

    Enum.join(changes ++ missing ++ [summary], "\n")
  end

  @doc "A report of import errors, one per line."
  @spec errors_report([Error.t()]) :: String.t()
  def errors_report(errors) do
    lines = Enum.map(errors, &("  " <> Error.format(&1)))
    Enum.join(["Nothing was imported:" | lines], "\n")
  end
end
