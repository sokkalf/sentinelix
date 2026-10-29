defmodule Sentinelix.Monitoring do
  @moduledoc """
  The Monitoring context: monitors, their check results (heartbeats) and
  incidents.

  ## PubSub events

  All events are broadcast on `Sentinelix.PubSub` after the change has been
  committed.

  Topic `"monitors"` (see `subscribe_monitors/0`) – configuration changes:

    * `{:monitor_created, %Monitor{}}`
    * `{:monitor_updated, %Monitor{}}` – also sent by `toggle_monitor/1`
    * `{:monitor_deleted, %Monitor{}}`

  Topic `"monitor:<id>"` (see `subscribe_monitor/1`) – everything about a
  single monitor:

    * `{:monitor_updated, %Monitor{}}` and `{:monitor_deleted, %Monitor{}}`
    * `{:check_result, %CheckResult{}}`
    * `{:incident_opened, %Incident{}}` and `{:incident_resolved, %Incident{}}`
  """

  import Ecto.Query, warn: false

  alias Phoenix.PubSub
  alias Sentinelix.Repo
  alias Sentinelix.Monitoring.{CheckResult, Incident, Monitor}

  @pubsub Sentinelix.PubSub
  @monitors_topic "monitors"
  @default_results_limit 50

  @type monitor_ref :: Monitor.t() | pos_integer()

  ## PubSub

  @doc """
  Subscribes the caller to monitor configuration changes (`"monitors"`).
  """
  def subscribe_monitors, do: PubSub.subscribe(@pubsub, @monitors_topic)

  @doc """
  Subscribes the caller to events of a single monitor (`"monitor:<id>"`).
  """
  @spec subscribe_monitor(monitor_ref()) :: :ok | {:error, term()}
  def subscribe_monitor(monitor), do: PubSub.subscribe(@pubsub, monitor_topic(monitor))

  @doc """
  Unsubscribes the caller from events of a single monitor.
  """
  @spec unsubscribe_monitor(monitor_ref()) :: :ok
  def unsubscribe_monitor(monitor), do: PubSub.unsubscribe(@pubsub, monitor_topic(monitor))

  @doc """
  The PubSub topic for a single monitor.
  """
  @spec monitor_topic(monitor_ref()) :: String.t()
  def monitor_topic(monitor), do: "monitor:#{monitor_id(monitor)}"

  defp broadcast(topic, message), do: PubSub.broadcast(@pubsub, topic, message)

  defp broadcast_monitor_change({:ok, %Monitor{} = monitor} = result, event) do
    broadcast(@monitors_topic, {event, monitor})

    if event != :monitor_created do
      broadcast(monitor_topic(monitor), {event, monitor})
    end

    result
  end

  defp broadcast_monitor_change(error, _event), do: error

  ## Monitors

  @doc """
  Returns the list of monitors, ordered by name.

  ## Options

    * `:enabled` – only return enabled (`true`) or disabled (`false`) monitors
    * `:type` – only return monitors of the given type (or list of types)
  """
  @spec list_monitors(keyword()) :: [Monitor.t()]
  def list_monitors(opts \\ []) do
    Monitor
    |> filter_monitors(opts)
    |> order_by([m], asc: fragment("lower(?)", m.name), asc: m.id)
    |> Repo.all()
  end

  defp filter_monitors(query, opts) do
    Enum.reduce(opts, query, fn
      {:enabled, enabled}, q when is_boolean(enabled) ->
        where(q, [m], m.enabled == ^enabled)

      {:type, types}, q when is_list(types) ->
        where(q, [m], m.type in ^types)

      {:type, type}, q ->
        where(q, [m], m.type == ^type)
    end)
  end

  @doc """
  Gets a single monitor. Raises `Ecto.NoResultsError` if it does not exist.
  """
  @spec get_monitor!(pos_integer()) :: Monitor.t()
  def get_monitor!(id), do: Repo.get!(Monitor, id)

  @doc """
  Gets a single monitor, or `nil` if it does not exist.
  """
  @spec get_monitor(pos_integer()) :: Monitor.t() | nil
  def get_monitor(id), do: Repo.get(Monitor, id)

  @doc """
  Gets a push monitor by its push token, or `nil`. Backed by a unique index.
  """
  @spec get_monitor_by_push_token(String.t()) :: Monitor.t() | nil
  def get_monitor_by_push_token(token) when is_binary(token) do
    Monitor
    |> where([m], m.type == :push)
    |> where([m], fragment("?->>'push_token'", m.settings) == ^token)
    |> Repo.one()
  end

  @doc """
  Creates a monitor.
  """
  @spec create_monitor(map()) :: {:ok, Monitor.t()} | {:error, Ecto.Changeset.t()}
  def create_monitor(attrs \\ %{}) do
    %Monitor{}
    |> Monitor.changeset(attrs)
    |> Repo.insert()
    |> broadcast_monitor_change(:monitor_created)
  end

  @doc """
  Updates a monitor.
  """
  @spec update_monitor(Monitor.t(), map()) :: {:ok, Monitor.t()} | {:error, Ecto.Changeset.t()}
  def update_monitor(%Monitor{} = monitor, attrs) do
    monitor
    |> Monitor.changeset(attrs)
    |> Repo.update()
    |> broadcast_monitor_change(:monitor_updated)
  end

  @doc """
  Enables a disabled monitor or disables an enabled one.

  Broadcasts `{:monitor_updated, monitor}`.
  """
  @spec toggle_monitor(Monitor.t()) :: {:ok, Monitor.t()} | {:error, Ecto.Changeset.t()}
  def toggle_monitor(%Monitor{} = monitor) do
    monitor
    |> Ecto.Changeset.change(enabled: not monitor.enabled)
    |> Repo.update()
    |> broadcast_monitor_change(:monitor_updated)
  end

  @doc """
  Deletes a monitor together with its check results and incidents.
  """
  @spec delete_monitor(Monitor.t()) :: {:ok, Monitor.t()} | {:error, Ecto.Changeset.t()}
  def delete_monitor(%Monitor{} = monitor) do
    monitor
    |> Repo.delete()
    |> broadcast_monitor_change(:monitor_deleted)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking monitor changes.
  """
  @spec change_monitor(Monitor.t(), map()) :: Ecto.Changeset.t()
  def change_monitor(%Monitor{} = monitor, attrs \\ %{}) do
    Monitor.changeset(monitor, attrs)
  end

  ## Check results

  @doc """
  Records the result of a check run for a monitor.

  `checked_at` defaults to now. Broadcasts `{:check_result, result}` on the
  monitor's topic.

      record_result(monitor, %{status: :up, response_time_ms: 42, status_code: 200})
  """
  @spec record_result(monitor_ref(), map()) ::
          {:ok, CheckResult.t()} | {:error, Ecto.Changeset.t()}
  def record_result(monitor, attrs) do
    id = monitor_id(monitor)

    %CheckResult{monitor_id: id, checked_at: DateTime.utc_now()}
    |> CheckResult.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, result} ->
        broadcast(monitor_topic(id), {:check_result, result})
        {:ok, result}

      error ->
        error
    end
  end

  @doc """
  Returns the most recent check results of a monitor, newest first.
  """
  @spec latest_results(monitor_ref(), pos_integer()) :: [CheckResult.t()]
  def latest_results(monitor, limit \\ @default_results_limit) do
    monitor
    |> results_query()
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns the most recent check result of a monitor, or `nil`.
  """
  @spec get_latest_result(monitor_ref()) :: CheckResult.t() | nil
  def get_latest_result(monitor) do
    monitor
    |> results_query()
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns a map of monitor id => most recent check result, for all monitors
  that have at least one result.
  """
  @spec latest_result_per_monitor() :: %{pos_integer() => CheckResult.t()}
  def latest_result_per_monitor do
    CheckResult
    |> distinct([r], r.monitor_id)
    |> order_by([r], asc: r.monitor_id, desc: r.checked_at, desc: r.id)
    |> Repo.all()
    |> Map.new(&{&1.monitor_id, &1})
  end

  defp results_query(monitor) do
    id = monitor_id(monitor)

    CheckResult
    |> where([r], r.monitor_id == ^id)
    |> order_by([r], desc: r.checked_at, desc: r.id)
  end

  ## Incidents

  @doc """
  Opens an incident for a monitor on a status transition.

  Requires `:from_status` and `:to_status`; `:started_at` defaults to now and
  `:message` is optional. A monitor can only have one open incident at a
  time. Broadcasts `{:incident_opened, incident}` on the monitor's topic.
  """
  @spec open_incident(monitor_ref(), map()) ::
          {:ok, Incident.t()} | {:error, Ecto.Changeset.t()}
  def open_incident(monitor, attrs) do
    id = monitor_id(monitor)

    %Incident{monitor_id: id, started_at: DateTime.utc_now()}
    |> Incident.open_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, incident} ->
        broadcast(monitor_topic(id), {:incident_opened, incident})
        {:ok, incident}

      error ->
        error
    end
  end

  @doc """
  Resolves an open incident.

  ## Options

    * `:resolved_at` – when the incident ended (defaults to now)

  Returns `{:error, :already_resolved}` if the incident was already resolved.
  Broadcasts `{:incident_resolved, incident}` on the monitor's topic.
  """
  @spec resolve_incident(Incident.t(), keyword()) ::
          {:ok, Incident.t()} | {:error, :already_resolved | Ecto.Changeset.t()}
  def resolve_incident(incident, opts \\ [])

  def resolve_incident(%Incident{resolved_at: %DateTime{}}, _opts),
    do: {:error, :already_resolved}

  def resolve_incident(%Incident{} = incident, opts) do
    resolved_at = Keyword.get_lazy(opts, :resolved_at, &DateTime.utc_now/0)

    incident
    |> Incident.resolve_changeset(%{resolved_at: resolved_at})
    |> Repo.update()
    |> case do
      {:ok, incident} ->
        broadcast(monitor_topic(incident.monitor_id), {:incident_resolved, incident})
        {:ok, incident}

      error ->
        error
    end
  end

  @doc """
  Returns the open (unresolved) incident of a monitor, or `nil`.
  """
  @spec get_open_incident(monitor_ref()) :: Incident.t() | nil
  def get_open_incident(monitor) do
    id = monitor_id(monitor)

    Incident
    |> where([i], i.monitor_id == ^id and is_nil(i.resolved_at))
    |> Repo.one()
  end

  @doc """
  Returns the incidents of a monitor, most recent first.
  """
  @spec list_incidents(monitor_ref(), pos_integer()) :: [Incident.t()]
  def list_incidents(monitor, limit \\ @default_results_limit) do
    id = monitor_id(monitor)

    Incident
    |> where([i], i.monitor_id == ^id)
    |> order_by([i], desc: i.started_at, desc: i.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp monitor_id(%Monitor{id: id}) when is_integer(id), do: id
  defp monitor_id(id) when is_integer(id), do: id
end
