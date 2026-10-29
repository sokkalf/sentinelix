defmodule SentinelixWeb.Telemetry do
  @moduledoc """
  Telemetry metrics.

  `metrics/0` are shown in the LiveDashboard (`/admin/dashboard`);
  `prometheus_metrics/0` are collected by a `Peep` reporter and exported on
  `/metrics` together with the per-monitor gauges of `Sentinelix.Metrics`.
  """
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Prometheus reporter (see Sentinelix.Metrics)
      {Peep, name: Sentinelix.Metrics.peep(), metrics: prometheus_metrics()},
      # Certificate days remaining per monitor, for Sentinelix.Metrics
      Sentinelix.Metrics.CheckMeta
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("sentinelix.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("sentinelix.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("sentinelix.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("sentinelix.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("sentinelix.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Monitoring engine
      summary("sentinelix.check.stop.duration",
        tags: [:monitor_type],
        unit: {:native, :millisecond},
        description: "Check run time, including the engine overhead"
      ),
      summary("sentinelix.check.stop.response_time_ms",
        tags: [:monitor_type],
        description: "Response time reported by the check"
      ),
      counter("sentinelix.check.stop.count",
        tags: [:monitor_type, :status],
        description: "Checks run, by recorded status"
      ),
      counter("sentinelix.monitor.status_changed.count",
        tags: [:monitor_type, :to],
        description: "Monitor status changes, by new status"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  @doc """
  Metrics exported in Prometheus format on `/metrics`.

  Names are prefixed by the Peep exporter's naming (dots become
  underscores). VM measurements come from the default `telemetry_poller`.
  """
  def prometheus_metrics do
    [
      # Monitoring engine
      counter("sentinelix.checks.total",
        event_name: [:sentinelix, :check, :stop],
        tags: [:monitor_type, :status, :error],
        tag_values: &check_tags/1,
        description: "Checks run, by monitor type, recorded status and error"
      ),
      distribution("sentinelix.check.duration.milliseconds",
        event_name: [:sentinelix, :check, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:monitor_type],
        description: "Check run time in milliseconds"
      ),
      counter("sentinelix.monitor.status_changes.total",
        event_name: [:sentinelix, :monitor, :status_changed],
        tags: [:monitor_type, :from, :to],
        description: "Monitor status changes"
      ),

      # Phoenix
      distribution("phoenix.router_dispatch.duration.milliseconds",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:route],
        description: "Request handling time by route in milliseconds"
      ),
      counter("phoenix.requests.total",
        event_name: [:phoenix, :endpoint, :stop],
        tags: [:method, :status],
        tag_values: &request_tags/1,
        description: "HTTP requests by method and response status"
      ),
      counter("phoenix.live_view.mount.total",
        event_name: [:phoenix, :live_view, :mount, :stop],
        tags: [:view],
        tag_values: &live_view_tags/1,
        description: "LiveView mounts"
      ),

      # Database
      distribution("sentinelix.repo.query.total_time.milliseconds",
        event_name: [:sentinelix, :repo, :query],
        measurement: :total_time,
        unit: {:native, :millisecond},
        description: "Database query time including queueing in milliseconds"
      ),
      distribution("sentinelix.repo.query.queue_time.milliseconds",
        event_name: [:sentinelix, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :millisecond},
        description: "Time spent waiting for a database connection in milliseconds"
      ),

      # VM
      last_value("vm.memory.total.bytes",
        event_name: [:vm, :memory],
        measurement: :total,
        description: "Total memory allocated by the BEAM"
      ),
      last_value("vm.memory.processes.bytes",
        event_name: [:vm, :memory],
        measurement: :processes,
        description: "Memory used by processes"
      ),
      last_value("vm.memory.binary.bytes",
        event_name: [:vm, :memory],
        measurement: :binary,
        description: "Memory used by binaries"
      ),
      last_value("vm.memory.ets.bytes",
        event_name: [:vm, :memory],
        measurement: :ets,
        description: "Memory used by ETS tables"
      ),
      last_value("vm.run_queue_lengths.total",
        event_name: [:vm, :total_run_queue_lengths],
        measurement: :total,
        description: "Run queue length (CPU and IO schedulers)"
      ),
      last_value("vm.process_count",
        event_name: [:vm, :system_counts],
        measurement: :process_count,
        description: "Number of processes"
      ),
      last_value("vm.atom_count",
        event_name: [:vm, :system_counts],
        measurement: :atom_count,
        description: "Number of atoms"
      ),
      last_value("vm.port_count",
        event_name: [:vm, :system_counts],
        measurement: :port_count,
        description: "Number of ports"
      )
    ]
  end

  @doc false
  def check_tags(metadata) do
    %{
      monitor_type: metadata.monitor_type,
      status: metadata.status,
      error: metadata[:error] || :none
    }
  end

  @doc false
  def request_tags(%{conn: conn}), do: %{method: conn.method, status: conn.status}

  @doc false
  def live_view_tags(%{socket: socket}), do: %{view: inspect(socket.view)}

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {SentinelixWeb, :count_users, []}
    ]
  end
end
