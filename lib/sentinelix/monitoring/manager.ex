defmodule Sentinelix.Monitoring.Manager do
  @moduledoc """
  Keeps the running workers in sync with the monitors in the database.

  On start it starts a worker for every enabled monitor (retrying later if
  the database is unavailable). It then follows the `"monitors"` topic:

    * `:monitor_created` – starts a worker if the monitor is enabled,
    * `:monitor_updated` (also sent when toggling) – restarts the worker with
      the new configuration, or stops it if the monitor got disabled,
    * `:monitor_deleted` – stops the worker.

  Monitors whose type has no registered check (see `Sentinelix.Checks`) are
  skipped.
  """

  use GenServer

  require Logger

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Monitor
  alias Sentinelix.Monitoring.Supervisor, as: Engine

  @reload_delay_ms 5_000

  def start_link(opts) do
    engine = Keyword.fetch!(opts, :engine)
    GenServer.start_link(__MODULE__, engine, name: Module.concat(engine, Manager))
  end

  @impl true
  def init(engine) do
    :ok = Monitoring.subscribe_monitors()
    {:ok, %{engine: engine}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl true
  def handle_info(:load, state), do: {:noreply, load(state)}

  def handle_info({:monitor_created, %Monitor{} = monitor}, state) do
    start(monitor, state)
    {:noreply, state}
  end

  def handle_info({:monitor_updated, %Monitor{} = monitor}, state) do
    Engine.stop_worker(monitor, state.engine)
    start(monitor, state)
    {:noreply, state}
  end

  def handle_info({:monitor_deleted, %Monitor{} = monitor}, state) do
    Engine.stop_worker(monitor, state.engine)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("#{inspect(__MODULE__)} ignoring unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  defp load(state) do
    Enum.each(Monitoring.list_monitors(enabled: true), &start(&1, state))
    state
  rescue
    error ->
      Logger.error(
        "Could not load monitors, retrying in #{@reload_delay_ms} ms: " <>
          Exception.message(error)
      )

      Process.send_after(self(), :load, @reload_delay_ms)
      state
  end

  defp start(%Monitor{enabled: false}, _state), do: :ok

  defp start(%Monitor{} = monitor, state) do
    case Engine.start_worker(monitor, state.engine) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, :no_check} ->
        Logger.debug("No check available for #{monitor.type} monitor #{monitor.id}, not starting")

      {:error, reason} ->
        Logger.error("Could not start worker for monitor #{monitor.id}: #{inspect(reason)}")
    end
  end
end
