defmodule SentinelixWeb.Services.MonitorService do
  use GenServer
  alias Sentinelix.Monitor
  alias Phoenix.PubSub

  @name __MODULE__
  @max_entries 50

  ## ------------------------------------------------------------------
  ## Public API
  ## ------------------------------------------------------------------

  # Start the GenServer under a supervisor
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc """
  Store the latest monitor data in memory.

  It keeps only the last @max_entries updates for each monitor.
  """
  def update_monitor(%Monitor{name: name, type: type} = monitor_data) do
    GenServer.cast(@name, {:update_monitor, name, type, monitor_data})
  end

  @doc """
  Fetch the last `n` entries for a specific monitor.
  """
  def get_monitor_data(name, type, n) do
    GenServer.call(@name, {:get_monitor_data, {name, type}, n})
  end

  @doc """
  Return all in-memory monitors (with all their stored entries).
  """
  def list_all_monitors() do
    GenServer.call(@name, :list_all_monitors)
  end

  ## Placeholder functions for future DB interactions:

  @doc """
  Save the current in-memory state to the database.
  """
  def persist_all_in_db do
    GenServer.cast(@name, :persist_all_in_db)
  end

  @doc """
  Load initial state from the database into this GenServer's memory.
  """
  def load_from_db do
    GenServer.cast(@name, :load_from_db)
  end

  ## ------------------------------------------------------------------
  ## GenServer callbacks
  ## ------------------------------------------------------------------

  @impl true
  def init(:ok) do
    PubSub.subscribe(Sentinelix.PubSub, "MonitorUpdate")
    # State will be a map of:
    # %{
    #   {monitor_name, monitor_type} => [latest_monitor_data_structs_in_reverse_chronological_order]
    # }
    state = %{}

    # Optionally load from DB on startup
    # (uncomment when implementing real DB logic)
    # state = do_load_from_db()

    {:ok, state}
  end

  @impl true
  def handle_cast({:update_monitor, name, type, monitor_data}, state) do
    key = {name, type}
    old_entries = Map.get(state, key, [])

    registered_types = case Cachex.get(:monitor_cache, name) do
      {:ok, nil} -> [type]
      {:ok, types} -> [type | types] |> Enum.uniq()
    end
    Cachex.put(:monitor_cache, name, registered_types)

    # Prepend new data and truncate to @max_entries
    new_entries = [monitor_data | old_entries] |> Enum.take(@max_entries)

    new_state = Map.put(state, key, new_entries)

    # Placeholder for saving an individual monitor update to DB
    persist_data_in_db(monitor_data)
    PubSub.broadcast(Sentinelix.PubSub, "WebUpdate", :updated)

    {:noreply, new_state}
  end

  def handle_cast(:persist_all_in_db, state) do
    # Placeholder: persist everything in memory to DB
    persist_all_monitors_in_db(state)
    {:noreply, state}
  end

  def handle_cast(:load_from_db, _state) do
    # Placeholder: load monitors from DB and overwrite state
    new_state = do_load_from_db()
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:get_monitor_data, key, n}, _from, state) do
    data = Map.get(state, key, []) |> Enum.take(n)
    {:reply, data, state}
  end

  def handle_call(:list_all_monitors, _from, state) do
    {:reply, Map.keys(state), state}
  end

  @impl true
  def handle_info(monitor_data, state) do
    update_monitor(monitor_data)
    {:noreply, state}
  end

  ## ------------------------------------------------------------------
  ## Private helper functions
  ## ------------------------------------------------------------------

  # You can move these DB placeholders to a separate module or context.
  defp persist_data_in_db(_monitor_data) do
    # Placeholder: persist single monitor data to DB
    :ok
  end

  defp persist_all_monitors_in_db(_all_data) do
    # Placeholder: persist entire map of monitor data to DB
    :ok
  end

  defp do_load_from_db do
    # Placeholder: load data from DB and return it as the GenServer's state
    # Expecting a map of {name, type} -> [Monitor structs]
    %{}
  end
end
