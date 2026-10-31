defmodule SentinelixWeb.MonitorIndex do
  @moduledoc """
  A live index of all monitors for the LiveViews that show their current
  status (the dashboard, wall displays): per monitor id an entry with

    * `monitor` – the monitor,
    * `latest` – its latest check result (or nil),
    * `status` – its status as shown
      (`SentinelixWeb.MonitorComponents.display_status/2`),
    * `warning` – whether its worker has raised a warning,
    * `maintenance` – the maintenance windows it's in now,
    * `checks` – its check result counts over the last 24 hours, for the
      uptime (see `Sentinelix.Monitoring.Grouping`).

  The entries are `Sentinelix.Monitoring.Grouping` entries. `load/0` builds
  the index, `subscribe/1` subscribes the LiveView to the changes and
  `handle_message/2` applies them:

      def handle_info(message, socket) do
        case MonitorIndex.handle_message(socket.assigns.index, message) do
          {:ok, index} -> {:noreply, assign(socket, index: index)}
          :ignore -> {:noreply, socket}
        end
      end

  The index holds whole monitors (targets, settings): LiveViews shown
  without a login must render only what they pick from it.
  """

  import SentinelixWeb.MonitorComponents, only: [display_status: 2]

  alias Sentinelix.{Maintenance, Monitoring, Stats}

  @uptime_window {24, :hour}

  @type entry :: %{
          monitor: Monitoring.Monitor.t(),
          latest: Monitoring.CheckResult.t() | nil,
          status: atom(),
          warning: boolean(),
          maintenance: list(),
          checks: %{atom() => non_neg_integer()} | nil
        }

  @type t :: %{pos_integer() => entry()}

  @doc "The window of the check counts (`checks`): 24 hours."
  @spec uptime_window() :: {pos_integer(), :hour}
  def uptime_window, do: @uptime_window

  @doc "Builds the index of all monitors."
  @spec load() :: t()
  def load do
    monitors = Monitoring.list_monitors()
    ids = Enum.map(monitors, & &1.id)
    latest = Monitoring.latest_result_per_monitor()
    maintenance = Maintenance.active_windows_for(ids)
    checks = Stats.summaries(ids, @uptime_window)

    Map.new(monitors, fn monitor ->
      entry =
        entry(
          monitor,
          Map.get(latest, monitor.id),
          Map.get(maintenance, monitor.id, []),
          checks |> Map.get(monitor.id) |> check_counts()
        )

      {monitor.id, entry}
    end)
  end

  @doc """
  Subscribes the caller to the changes of the index's monitors, new
  monitors and maintenance windows, for `handle_message/2`.
  """
  @spec subscribe(t()) :: :ok
  def subscribe(index) do
    Monitoring.subscribe_monitors()
    Enum.each(index, fn {_id, entry} -> Monitoring.subscribe_monitor(entry.monitor) end)
    Maintenance.subscribe()
    :ok
  end

  @doc """
  Applies a message the subscriptions deliver: `{:ok, index}` when it
  changed the index, `:ignore` for other messages (and changes of
  monitors not in it).
  """
  @spec handle_message(t(), term()) :: {:ok, t()} | :ignore
  def handle_message(index, {:monitor_created, monitor}) do
    Monitoring.subscribe_monitor(monitor)

    maintenance = Maintenance.active_windows_for([monitor.id])

    {:ok,
     Map.put(index, monitor.id, entry(monitor, nil, Map.get(maintenance, monitor.id, []), nil))}
  end

  def handle_message(index, {:monitor_updated, monitor}) do
    update_entry(index, monitor.id, fn entry ->
      %{entry | monitor: monitor, status: display_status(monitor, entry.latest)}
    end)
  end

  def handle_message(index, {:monitor_deleted, monitor}) do
    Monitoring.unsubscribe_monitor(monitor)
    {:ok, Map.delete(index, monitor.id)}
  end

  def handle_message(index, {:check_result, result}) do
    update_entry(index, result.monitor_id, fn entry ->
      checks = Stats.summaries([result.monitor_id], @uptime_window)[result.monitor_id]

      %{
        entry
        | latest: result,
          status: display_status(entry.monitor, result),
          checks: check_counts(checks)
      }
    end)
  end

  def handle_message(index, {event, monitor, _result})
      when event in [:warning_raised, :warning_cleared] do
    update_entry(index, monitor.id, &%{&1 | warning: event == :warning_raised})
  end

  def handle_message(index, {:maintenance_changed}) do
    maintenance = Maintenance.active_windows_for(Map.keys(index))

    {:ok,
     Map.new(index, fn {id, entry} ->
       {id, %{entry | maintenance: Map.get(maintenance, id, [])}}
     end)}
  end

  # Status changes are covered by the check result that caused them.
  def handle_message(_index, _message), do: :ignore

  defp entry(monitor, latest, maintenance, checks) do
    %{
      monitor: monitor,
      latest: latest,
      status: display_status(monitor, latest),
      warning: warning?(monitor),
      maintenance: maintenance,
      checks: checks
    }
  end

  defp check_counts(nil), do: nil
  defp check_counts(summary), do: Map.take(summary, [:up, :down, :unreachable])

  defp warning?(%{enabled: false}), do: false

  defp warning?(monitor) do
    case Monitoring.worker_info(monitor) do
      %{warning: warning} -> warning
      nil -> false
    end
  end

  defp update_entry(index, id, fun) do
    case Map.fetch(index, id) do
      {:ok, entry} -> {:ok, Map.put(index, id, fun.(entry))}
      :error -> :ignore
    end
  end
end
