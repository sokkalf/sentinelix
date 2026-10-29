defmodule Sentinelix.Monitoring.Supervisor do
  @moduledoc """
  The monitoring engine: supervises one `Sentinelix.Monitoring.Worker` per
  enabled monitor.

  Children (`:rest_for_one`):

    * a `Registry` of workers keyed by monitor id,
    * a `Task.Supervisor` the workers run their checks under,
    * a `DynamicSupervisor` for the workers,
    * the `Sentinelix.Monitoring.Manager`, which starts workers for the
      enabled monitors on boot and starts/restarts/stops them when monitors
      are created, updated, toggled or deleted.

  ## Options

  The application starts the engine with the options from
  `config :sentinelix, Sentinelix.Monitoring.Supervisor` (the test config
  disables the manager).

    * `:name` – the engine name (default `Sentinelix.Monitoring.Supervisor`).
      All other process names are derived from it, so tests can run an
      isolated engine. The functions below take it as their last argument.
    * `:manager` – whether to start the manager (default `true`). Without
      it, workers are only started with `start_worker/2`.
    * `:checks` – map of monitor type => check module (default
      `Sentinelix.Checks.modules/0`).
    * `:maintenance` – a module with an `active?(monitor, now)` function, or
      `nil` (default). See `Sentinelix.Monitoring.Worker`.
    * `:jitter` – random extra delay added to each scheduled check, as a
      fraction of the interval (default `0.05`).
  """

  use Supervisor

  alias Sentinelix.Monitoring.{Manager, Monitor, Worker}

  @default_jitter 0.05

  @type engine :: atom()

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    config = %{
      engine: name,
      checks: Keyword.get_lazy(opts, :checks, &Sentinelix.Checks.modules/0),
      maintenance: Keyword.get(opts, :maintenance),
      jitter: Keyword.get(opts, :jitter, @default_jitter),
      task_supervisor: task_supervisor(name)
    }

    manager =
      if Keyword.get(opts, :manager, true),
        do: [{Manager, engine: name}],
        else: []

    children =
      [
        {Registry, keys: :unique, name: registry(name), meta: [config: config]},
        {Task.Supervisor, name: task_supervisor(name)},
        {DynamicSupervisor, name: worker_supervisor(name), strategy: :one_for_one}
      ] ++ manager

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  def registry(engine \\ __MODULE__), do: Module.concat(engine, Registry)

  defp task_supervisor(engine), do: Module.concat(engine, TaskSupervisor)
  defp worker_supervisor(engine), do: Module.concat(engine, WorkerSupervisor)

  @doc false
  def config(engine \\ __MODULE__) do
    {:ok, config} = Registry.meta(registry(engine), :config)
    config
  end

  @doc """
  Starts a worker for `monitor`.

  Returns `{:error, :no_check}` if no check is registered for the monitor's
  type and `{:error, {:already_started, pid}}` if it is already running.
  """
  @spec start_worker(Monitor.t(), engine()) ::
          DynamicSupervisor.on_start_child() | {:error, :no_check}
  def start_worker(%Monitor{} = monitor, engine \\ __MODULE__) do
    config = config(engine)

    case Map.fetch(config.checks, monitor.type) do
      {:ok, check} ->
        spec = {Worker, monitor: monitor, check: check, config: config}
        DynamicSupervisor.start_child(worker_supervisor(engine), spec)

      :error ->
        {:error, :no_check}
    end
  end

  @doc """
  Stops the worker of a monitor, if running.
  """
  @spec stop_worker(Monitor.t() | pos_integer(), engine()) :: :ok
  def stop_worker(monitor, engine \\ __MODULE__) do
    case whereis(monitor, engine) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(worker_supervisor(engine), pid)
    end

    :ok
  end

  @doc """
  The pid of a monitor's worker, or `nil`.
  """
  @spec whereis(Monitor.t() | pos_integer(), engine()) :: pid() | nil
  def whereis(monitor, engine \\ __MODULE__) do
    case Registry.lookup(registry(engine), monitor_id(monitor)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  The ids of all monitors that have a running worker.
  """
  @spec running_monitor_ids(engine()) :: [pos_integer()]
  def running_monitor_ids(engine \\ __MODULE__) do
    registry(engine)
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end

  defp monitor_id(%Monitor{id: id}), do: id
  defp monitor_id(id) when is_integer(id), do: id
end
