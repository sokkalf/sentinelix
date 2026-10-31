defmodule Sentinelix.Metrics do
  @moduledoc """
  Prometheus metrics.

  `export/1` renders the Prometheus text exposition format, made of

    * per-monitor gauges, computed when scraped from the monitors in the
      database, their workers' state and the latest check results – so they
      reflect the current state right after boot and disappear when a
      monitor is deleted;
    * the `Telemetry.Metrics` collected by the `Peep` reporter started in
      `SentinelixWeb.Telemetry` (BEAM, Phoenix, Ecto and check engine
      metrics, see `SentinelixWeb.Telemetry.prometheus_metrics/0`).

  ## Per-monitor metrics

  All carry the labels `monitor_id`, `monitor` (the name) and `type`.

    * `sentinelix_monitor_enabled` – 1 if the monitor is enabled, else 0.
    * `sentinelix_monitor_up` – 1 if up, 0 if down; absent while the
      monitor is pending (new or retrying), in maintenance, unreachable (its
      parent is down) or disabled.
    * `sentinelix_monitor_status{status="up|down|pending|maintenance|unreachable"}` –
      1 for the current status, 0 for the others (enabled monitors only).
    * `sentinelix_monitor_warning` – 1 while a check reports a warning (e.g.
      a certificate close to expiry; enabled monitors only).
    * `sentinelix_monitor_response_time_ms` – response time of the latest
      check, if it reported one.
    * `sentinelix_monitor_last_check_timestamp_seconds` – Unix time of the
      latest check.
    * `sentinelix_monitor_cert_days_remaining` – days until the certificate
      expires, for monitors whose last check reported it (cert monitors).
    * `sentinelix_monitor_labels` – always 1; carries the monitor's labels
      (see `Sentinelix.Monitoring.Labels`), automatic ones included
      (`label_type`, `label_host`), as `label_<key>="<value>"`, in
      the style of kube-state-metrics' `kube_pod_labels`.

  ## Monitor labels

  Monitor labels are not added to every gauge: arbitrary user-defined keys
  would change the series of all metrics whenever a label is edited and
  multiply their cardinality. Instead, the single info metric
  `sentinelix_monitor_labels` carries them and can be joined in PromQL:

      sentinelix_monitor_up
        * on (monitor_id) group_left (label_env)
        sentinelix_monitor_labels

  Label keys become Prometheus label names prefixed with `label_`, with
  characters other than `a-z`, `0-9` and `_` replaced by `_`
  (`team/owner` -> `label_team_owner`); if two keys end up the same, the
  first in sorted order wins. Labels without a value have the value `""`.
  """

  alias Sentinelix.Metrics.CheckMeta
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Labels
  alias Sentinelix.Monitoring.Supervisor, as: Engine
  alias Sentinelix.Monitoring.Worker

  @peep Sentinelix.Peep
  @statuses [:up, :down, :pending, :maintenance, :unreachable]

  @gauges [
    {"sentinelix_monitor_enabled", "Whether the monitor is enabled (1) or paused (0)."},
    {"sentinelix_monitor_up",
     "Whether the monitor is up (1) or down (0). Absent while pending, in maintenance, unreachable or disabled."},
    {"sentinelix_monitor_status", "Current status of the monitor (1 for the current status)."},
    {"sentinelix_monitor_warning",
     "Whether the monitor's checks report a warning (e.g. a certificate close to expiry)."},
    {"sentinelix_monitor_response_time_ms", "Response time of the latest check in milliseconds."},
    {"sentinelix_monitor_last_check_timestamp_seconds", "Unix time of the latest check."},
    {"sentinelix_monitor_cert_days_remaining",
     "Days until the monitored TLS certificate expires."},
    {"sentinelix_monitor_labels",
     "The monitor's labels as label_<key> (always 1). Join on monitor_id."}
  ]

  @doc "The name of the `Peep` reporter."
  def peep, do: @peep

  @doc """
  Renders all metrics in the Prometheus text format.

  ## Options

    * `:engine` – the monitoring engine to read worker state from (default
      `Sentinelix.Monitoring.Supervisor`).
  """
  @spec export(keyword()) :: iodata()
  def export(opts \\ []) do
    peep =
      case Peep.get_all_metrics(@peep) do
        nil -> ["# EOF\n"]
        metrics -> Peep.Prometheus.export(metrics)
      end

    [monitor_metrics(opts), peep]
  end

  @doc """
  Renders the per-monitor gauges in the Prometheus text format. Takes the
  same options as `export/1`.
  """
  @spec monitor_metrics(keyword()) :: iodata()
  def monitor_metrics(opts \\ []) do
    samples =
      opts
      |> Keyword.get(:engine, Engine)
      |> rows()
      |> Enum.flat_map(&samples/1)
      |> Enum.group_by(fn {name, _labels, _value} -> name end, fn {_name, labels, value} ->
        {labels, value}
      end)

    for {name, help} <- @gauges, do: gauge(name, help, Map.get(samples, name, []))
  end

  defp rows(engine) do
    monitors = Monitoring.list_monitors()
    latest = Monitoring.latest_result_per_monitor()
    CheckMeta.prune(Enum.map(monitors, & &1.id))
    days_remaining = CheckMeta.days_remaining()

    Enum.map(monitors, fn monitor ->
      info = if monitor.enabled, do: worker_info(monitor, engine)
      result = Map.get(latest, monitor.id)

      %{
        labels: labels(monitor),
        monitor_labels: monitor.all_labels,
        enabled: monitor.enabled,
        status: status(monitor, info, result),
        warning: info != nil and info.warning == true,
        result: result,
        days_remaining: Map.get(days_remaining, monitor.id)
      }
    end)
  end

  # {metric name, labels, value} samples of a monitor
  defp samples(%{labels: labels} = row) do
    [{"sentinelix_monitor_enabled", labels, bool(row.enabled)}] ++
      status_samples(row) ++
      result_samples(row) ++ cert_samples(row) ++ label_samples(row)
  end

  defp label_samples(%{labels: labels, monitor_labels: monitor_labels}) do
    extra =
      monitor_labels
      |> Labels.to_list()
      |> Enum.map(fn {key, value} ->
        {"label_" <> String.replace(key, ~r/[^a-z0-9_]/, "_"), value}
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    [{"sentinelix_monitor_labels", labels ++ extra, 1}]
  end

  defp status_samples(%{enabled: false}), do: []

  defp status_samples(%{labels: labels, status: current} = row) do
    up =
      if current in [:up, :down],
        do: [{"sentinelix_monitor_up", labels, bool(current == :up)}],
        else: []

    statuses =
      for status <- @statuses,
          do: {"sentinelix_monitor_status", labels ++ [status: status], bool(status == current)}

    up ++ statuses ++ [{"sentinelix_monitor_warning", labels, bool(row.warning)}]
  end

  defp result_samples(%{result: nil}), do: []

  defp result_samples(%{labels: labels, result: result}) do
    response_time =
      if is_integer(result.response_time_ms),
        do: [{"sentinelix_monitor_response_time_ms", labels, result.response_time_ms}],
        else: []

    timestamp = DateTime.to_unix(result.checked_at)
    response_time ++ [{"sentinelix_monitor_last_check_timestamp_seconds", labels, timestamp}]
  end

  defp cert_samples(%{labels: labels, days_remaining: days}) when is_integer(days),
    do: [{"sentinelix_monitor_cert_days_remaining", labels, days}]

  defp cert_samples(_row), do: []

  defp labels(monitor), do: [monitor_id: monitor.id, monitor: monitor.name, type: monitor.type]

  # A disabled monitor has no status. An enabled one has its worker's status;
  # the latest result tells if it is in maintenance or unreachable (the
  # worker keeps its status then) and stands in when no worker is running.
  defp status(%{enabled: false}, _info, _result), do: nil

  defp status(_monitor, _info, %{status: status}) when status in [:maintenance, :unreachable],
    do: status

  defp status(_monitor, %{status: status}, _result), do: status
  defp status(_monitor, nil, %{status: status}), do: status
  defp status(_monitor, nil, nil), do: :pending

  defp worker_info(monitor, engine) do
    Worker.info(monitor, engine)
  catch
    # The worker stopped (or is busy) – report what the database knows.
    :exit, _reason -> nil
  end

  defp bool(true), do: 1
  defp bool(_), do: 0

  defp gauge(_name, _help, []), do: []

  defp gauge(name, help, samples) do
    [
      ["# HELP ", name, " ", help, ?\n],
      ["# TYPE ", name, " gauge\n"],
      Enum.map(samples, fn {labels, value} ->
        [name, ?{, format_labels(labels), "} ", Integer.to_string(value), ?\n]
      end)
    ]
  end

  defp format_labels(labels) do
    Enum.map_intersperse(labels, ?,, fn {key, value} ->
      [to_string(key), "=\"", escape(to_string(value)), ?"]
    end)
  end

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end
end
