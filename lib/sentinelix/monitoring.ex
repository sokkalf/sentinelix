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
    * the status events below

  Topic `"status_changes"` (see `subscribe_status_changes/0`) – status events
  of all monitors, broadcast by `Sentinelix.Monitoring.Worker`:

    * `{:status_changed, %Monitor{}, old_status, new_status, %CheckResult{}}`
      – the monitor's status (`:pending`, `:up` or `:down`) changed.
    * `{:warning_raised, %Monitor{}, %CheckResult{}}` – the monitor is up
      but a check reported a warning (e.g. a TLS certificate close to
      expiry; the result's message says why).
    * `{:warning_cleared, %Monitor{}, %CheckResult{}}` – the warning is gone.
  """

  import Ecto.Query, warn: false

  alias Phoenix.PubSub
  alias Sentinelix.Monitoring.{CheckResult, Incident, Labels, Monitor, Settings, Worker}
  alias Sentinelix.Repo

  @pubsub Sentinelix.PubSub
  @monitors_topic "monitors"
  @status_changes_topic "status_changes"
  @default_results_limit 50

  @type monitor_ref :: Monitor.t() | pos_integer()

  ## PubSub

  @doc """
  Subscribes the caller to monitor configuration changes (`"monitors"`).
  """
  def subscribe_monitors, do: PubSub.subscribe(@pubsub, @monitors_topic)

  @doc """
  Subscribes the caller to the status events of all monitors
  (`"status_changes"`).
  """
  def subscribe_status_changes, do: PubSub.subscribe(@pubsub, @status_changes_topic)

  @doc false
  # Used by the monitoring worker: broadcasts a status event on the
  # "status_changes" topic and the monitor's own topic.
  def broadcast_status_event(monitor, event) do
    broadcast(@status_changes_topic, event)
    broadcast(monitor_topic(monitor), event)
  end

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
    * `:label` – only return monitors with the label `{key, value}`; a
      label without a value (`{key, ""}`) matches any value of `key`, see
      `Sentinelix.Monitoring.Labels.has?/2`. Can be given more than once.
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

      {:label, {key, ""}}, q ->
        where(q, [m], fragment("? \\? ?", m.labels, ^key))

      {:label, {key, value}}, q ->
        where(q, [m], fragment("? @> ?", m.labels, ^%{key => value}))
    end)
  end

  @doc """
  All label keys in use with their values, as a map of key => sorted
  values (`""` for labels without a value). For autocompletion.
  """
  @spec list_label_values() :: %{Labels.key() => [Labels.value()]}
  def list_label_values do
    from(m in Monitor,
      cross_join: l in fragment("jsonb_each_text(?)", m.labels),
      distinct: true,
      select: {l.key, l.value}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, values} -> {key, Enum.sort(values)} end)
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

  The notification channels marked as default are attached to it (see
  `Sentinelix.Notifications.attach_default_channels/1`); use
  `Sentinelix.Notifications.put_monitor_channels/2` afterwards to choose
  different ones.
  """
  @spec create_monitor(map()) :: {:ok, Monitor.t()} | {:error, Ecto.Changeset.t()}
  def create_monitor(attrs \\ %{}) do
    changeset = Monitor.changeset(%Monitor{}, attrs)

    changeset
    |> Repo.insert(write_options(changeset))
    |> tap(fn
      {:ok, monitor} -> Sentinelix.Notifications.attach_default_channels(monitor)
      _error -> :ok
    end)
    |> broadcast_monitor_change(:monitor_created)
  end

  @doc """
  Updates a monitor.
  """
  @spec update_monitor(Monitor.t(), map()) :: {:ok, Monitor.t()} | {:error, Ecto.Changeset.t()}
  def update_monitor(%Monitor{} = monitor, attrs) do
    changeset = Monitor.changeset(monitor, attrs)

    changeset
    |> Repo.update(write_options(changeset))
    |> broadcast_monitor_change(:monitor_updated)
  end

  # Ecto logs queries (at debug level) with the parameters before they are
  # dumped, i.e. secrets before they are encrypted. Writes that change
  # secrets are not logged.
  defp write_options(changeset) do
    if Ecto.Changeset.changed?(changeset, :secrets), do: [log: false], else: []
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

  @doc """
  Returns a new, unsaved monitor with the configuration of `source`: its
  type, settings, schedule, description and labels, named "<name> (copy)".

  Secrets (e.g. a PostgreSQL password) are not copied and have to be entered
  again; push monitors get a new push token. Notification channels,
  maintenance windows and status pages are memberships of the source, not
  part of the monitor.
  """
  @spec clone_monitor(Monitor.t()) :: Monitor.t()
  def clone_monitor(%Monitor{} = source) do
    %Monitor{
      name: copy_name(source.name),
      type: source.type,
      enabled: source.enabled,
      interval_seconds: source.interval_seconds,
      retry_interval_seconds: source.retry_interval_seconds,
      max_retries: source.max_retries,
      timeout_ms: source.timeout_ms,
      description: source.description,
      labels: source.labels,
      settings: clone_settings(source.type, source.settings),
      secrets: %{}
    }
  end

  @copy_suffix " (copy)"
  @max_name_length 255

  defp copy_name(name) do
    String.slice(name || "", 0, @max_name_length - String.length(@copy_suffix)) <> @copy_suffix
  end

  defp clone_settings(_type, nil), do: nil
  defp clone_settings(:push, settings), do: %{settings | push_token: Settings.generate_token()}
  defp clone_settings(_type, settings), do: settings

  ## Engine

  @doc """
  Runs a check of a monitor right away (asynchronously; the result arrives
  as `{:check_result, result}` on the monitor's topic).

  Returns `{:error, :not_running}` when the monitor has no running worker
  (it is disabled or its type has no check).
  """
  @spec check_now(monitor_ref()) :: :ok | {:error, :not_running}
  defdelegate check_now(monitor), to: Sentinelix.Monitoring.Worker

  @doc """
  The runtime state of a monitor's worker (see
  `Sentinelix.Monitoring.Worker.info/2`), or `nil` if it isn't running.
  """
  @spec worker_info(monitor_ref()) :: map() | nil
  defdelegate worker_info(monitor), to: Sentinelix.Monitoring.Worker, as: :info

  @default_push_message "OK"
  # Fits the `response_time_ms` integer column.
  @max_push_ping 2_147_483_647

  @doc """
  Records a push (heartbeat) for the push monitor with the given token.

  The push is handed to the monitor's worker, so it goes through the status
  state machine like any check result (status changes, incidents, events).
  Supported params (string keys, as received by the push endpoint):

    * `"status"` – `"up"` (default) or `"down"`
    * `"msg"` – a message (default `"OK"`)
    * `"ping"` – a response time in milliseconds (optional; ignored if it
      isn't a non-negative number)

  Returns the stored check result (`nil` if it could not be stored), or

    * `{:error, :not_found}` – no enabled push monitor has this token,
    * `{:error, :invalid_status}` – `"status"` is neither `"up"` nor `"down"`,
    * `{:error, :not_running}` – the monitor has no running worker.
  """
  @spec receive_push(String.t(), map()) ::
          {:ok, CheckResult.t() | nil}
          | {:error, :not_found | :invalid_status | :not_running}
  def receive_push(token, params \\ %{}) when is_binary(token) and is_map(params) do
    with %Monitor{enabled: true} = monitor <- get_monitor_by_push_token(token),
         {:ok, status} <- push_status(params["status"]) do
      details = %{
        message: push_message(params["msg"]),
        response_time_ms: push_ping(params["ping"])
      }

      case Worker.push(monitor, {status, details}) do
        {:error, :not_passive} -> {:error, :not_running}
        result -> result
      end
    else
      {:error, :invalid_status} -> {:error, :invalid_status}
      _ -> {:error, :not_found}
    end
  end

  defp push_status(status) when status in [nil, "", "up"], do: {:ok, :up}
  defp push_status("down"), do: {:ok, :down}
  defp push_status(_status), do: {:error, :invalid_status}

  defp push_message(message) when is_binary(message) do
    case String.trim(message) do
      "" -> @default_push_message
      message -> message
    end
  end

  defp push_message(_message), do: @default_push_message

  defp push_ping(ping) when is_binary(ping) do
    case Float.parse(ping) do
      {value, ""} when value >= 0 and value <= @max_push_ping -> round(value)
      _ -> nil
    end
  end

  defp push_ping(ping) when is_number(ping) and ping >= 0 and ping <= @max_push_ping,
    do: round(ping)

  defp push_ping(_ping), do: nil

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
