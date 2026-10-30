defmodule Sentinelix.Maintenance.Cache do
  @moduledoc """
  Keeps the enabled maintenance windows in memory, so that
  `Sentinelix.Maintenance.active?/2` (called by the monitoring engine after
  every check) doesn't query the database.

  The windows are stored in `:persistent_term` (reads are free; the term is
  only replaced when the windows actually changed). They are reloaded

    * on start,
    * when a window is created, updated or deleted (`refresh/0`, called by
      `Sentinelix.Maintenance`),
    * every minute, on the minute (a safety net for changes made outside
      the context).

  Whether a window is active is computed from the cached schedule at call
  time, so window starts and ends take effect immediately, not on the next
  reload. On every reload the cache also computes which windows are active
  and broadcasts `{:maintenance_changed}` on the `"maintenance"` topic when
  the windows or the set of active windows changed (so pages showing
  maintenance badges can update when a window starts or ends), and always
  on `refresh/0`.

  ## Options

    * `:autoload` – load on start and every minute (default `true`; the test
      config disables it since the SQL sandbox isn't available then).
  """

  use GenServer

  require Logger

  alias Sentinelix.Maintenance
  alias Sentinelix.Maintenance.Window

  @key {__MODULE__, :windows}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The cached enabled windows (with `monitor_ids` set).
  """
  @spec windows() :: [Window.t()]
  def windows, do: :persistent_term.get(@key, [])

  @doc """
  Reloads the windows from the database. A no-op when the cache isn't
  running.
  """
  @spec refresh() :: :ok
  def refresh do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :refresh), else: :ok
  end

  @doc false
  # Clears the cache (for tests).
  def reset do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :reset)
    :persistent_term.erase(@key)
    :ok
  end

  @impl true
  def init(opts) do
    state = %{autoload: Keyword.get(opts, :autoload, true), active: MapSet.new()}

    if state.autoload,
      do: {:ok, state, {:continue, :load}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:load, state) do
    {:noreply, state |> reload() |> schedule_tick()}
  end

  @impl true
  # Window changes are always broadcast (also of disabled windows).
  def handle_call(:refresh, _from, state), do: {:reply, :ok, reload(state, true)}

  def handle_call(:reset, _from, state) do
    :persistent_term.erase(@key)
    {:reply, :ok, %{state | active: MapSet.new()}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = reload(state)
    {:noreply, if(state.autoload, do: schedule_tick(state), else: state)}
  end

  def handle_info(message, state) do
    Logger.debug("#{inspect(__MODULE__)} ignoring unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  defp reload(state, broadcast? \\ false) do
    windows = Maintenance.load_windows()
    changed? = windows != windows()
    if changed?, do: :persistent_term.put(@key, windows)

    now = DateTime.utc_now()
    active = for w <- windows, Window.active?(w, now), into: MapSet.new(), do: w.id

    if broadcast? or changed? or active != state.active, do: Maintenance.broadcast_changed()
    %{state | active: active}
  rescue
    error ->
      # Keeps the previous windows; the next tick retries.
      Logger.error("Could not load maintenance windows: " <> Exception.message(error))
      state
  end

  # On the minute, so window starts and ends are broadcast promptly.
  defp schedule_tick(state) do
    ms = 60_000 - rem(System.system_time(:millisecond), 60_000) + 50
    Process.send_after(self(), :tick, ms)
    state
  end
end
