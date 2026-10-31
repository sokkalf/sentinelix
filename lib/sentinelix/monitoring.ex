defmodule Sentinelix.Monitoring do
  @moduledoc """
  The Monitoring context: monitors, their check results (heartbeats),
  incidents and dependencies (a monitor's parent, see `suggest_parent/1`
  and `Sentinelix.Monitoring.Worker`).

  ## PubSub events

  All events are broadcast on `Sentinelix.PubSub` after the change has been
  committed.

  Topic `"monitors"` (see `subscribe_monitors/0`) – configuration changes:

    * `{:monitor_created, %Monitor{}}`
    * `{:monitor_updated, %Monitor{}}` – also sent by `toggle_monitor/1`
    * `{:monitor_deleted, %Monitor{}}`

  Bulk changes (`put_labels/2`, `delete_labels/2`, `set_monitors_enabled/2`,
  `delete_monitors/1`) send one of these events per changed monitor.
  Deleting a monitor sends `:monitor_updated` for each of its children,
  which lose their parent.

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

  alias Sentinelix.Monitoring.{
    AutoLabels,
    CheckResult,
    Incident,
    Labels,
    Monitor,
    Selector,
    Settings,
    Worker
  }

  alias Sentinelix.Repo

  @pubsub Sentinelix.PubSub
  @monitors_topic "monitors"
  @status_changes_topic "status_changes"
  @default_results_limit 50
  # Key of the advisory lock that serialises parent changes.
  @parent_lock 4_801
  @parent_types [:ping, :tcp]
  @max_dependency_depth 1_000

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
    * `:label` – only return monitors with the label `{key, value}`, a
      user or automatic label (`all_labels`); a label without a value
      (`{key, ""}`) matches any value of `key`, see
      `Sentinelix.Monitoring.Labels.has?/2`. Can be given more than once.
    * `:selector` – only return monitors matching a
      `Sentinelix.Monitoring.Selector` (a struct, or a string that raises if
      it's invalid). It can't have `status` terms, see
      `Sentinelix.Monitoring.Selector.split_status/1`.
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
        where(q, [m], fragment("? \\? ?", m.all_labels, ^key))

      {:label, {key, value}}, q ->
        where(q, [m], fragment("? @> ?", m.all_labels, ^%{key => value}))

      {:selector, text}, q when is_binary(text) ->
        Selector.filter(q, Selector.parse!(text))

      {:selector, %Selector{} = selector}, q ->
        Selector.filter(q, selector)
    end)
  end

  @doc """
  All user label keys in use with their values, as a map of key => sorted
  values (`""` for labels without a value). For autocompletion in the
  label editor, so automatic labels are not included unless asked for.

  ## Options

    * `:automatic` – also include automatic labels (default `false`), e.g.
      to complete selectors.
  """
  @spec list_label_values(keyword()) :: %{Labels.key() => [Labels.value()]}
  def list_label_values(opts \\ []) do
    query =
      if Keyword.get(opts, :automatic, false),
        do: from(m in Monitor, cross_join: l in fragment("jsonb_each_text(?)", m.all_labels)),
        else: from(m in Monitor, cross_join: l in fragment("jsonb_each_text(?)", m.labels))

    from([_m, l] in query,
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

  A new parent (`parent_id`) that would make the monitor depend on itself,
  directly or through other monitors, is rejected with an error on
  `:parent_id`.
  """
  @spec update_monitor(Monitor.t(), map()) :: {:ok, Monitor.t()} | {:error, Ecto.Changeset.t()}
  def update_monitor(%Monitor{} = monitor, attrs) do
    monitor
    |> Monitor.changeset(attrs)
    |> update_with_parent()
    |> broadcast_monitor_change(:monitor_updated)
  end

  # A new parent is checked for cycles in a transaction holding an advisory
  # lock, so two concurrent parent changes (a -> b and b -> a) can't form a
  # cycle together. A new monitor has no children, so it can't be part of
  # a cycle.
  defp update_with_parent(%{valid?: true, changes: %{parent_id: parent_id}} = changeset)
       when is_integer(parent_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@parent_lock])

      changeset
      |> validate_no_cycle()
      |> Repo.update(write_options(changeset))
      |> case do
        {:ok, monitor} -> monitor
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp update_with_parent(changeset), do: Repo.update(changeset, write_options(changeset))

  defp validate_no_cycle(changeset) do
    parent_id = Ecto.Changeset.get_change(changeset, :parent_id)

    if changeset.data.id in [parent_id | ancestor_ids(parent_id)],
      do: Ecto.Changeset.add_error(changeset, :parent_id, "would create a dependency cycle"),
      else: changeset
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

  Its children lose their parent; each is broadcast as `{:monitor_updated,
  child}`.
  """
  @spec delete_monitor(Monitor.t()) :: {:ok, Monitor.t()} | {:error, Ecto.Changeset.t()}
  def delete_monitor(%Monitor{} = monitor) do
    children = child_ids([monitor.id])

    monitor
    |> Repo.delete()
    |> broadcast_monitor_change(:monitor_deleted)
    |> tap(fn
      {:ok, _monitor} -> broadcast_detached(children)
      _error -> :ok
    end)
  end

  # The ids of the children of the given monitors, except those among them.
  defp child_ids(ids) do
    Repo.all(from m in Monitor, where: m.parent_id in ^ids and m.id not in ^ids, select: m.id)
  end

  # The database detached the children of deleted monitors (`ON DELETE SET
  # NULL`); broadcast them so that their workers restart without a parent.
  defp broadcast_detached([]), do: :ok

  defp broadcast_detached(ids) do
    Monitor
    |> where([m], m.id in ^ids)
    |> Repo.all()
    |> Enum.each(&broadcast_monitor_change({:ok, &1}, :monitor_updated))
  end

  ## Bulk changes

  @doc """
  Adds labels to each of the given monitors (structs or ids; unknown ids
  are ignored), replacing the value of keys a monitor already has.
  `labels` is anything `Sentinelix.Monitoring.Labels` casts, e.g.
  `%{"env" => "prod"}` or `["env=prod", "legacy"]`.

  All monitors are changed in one transaction, or none if a change is
  invalid (e.g. a monitor would get more than the maximum number of
  labels): then the error changeset of the first such monitor is returned
  (its `data` is the monitor). Returns the monitors that changed; each is
  broadcast as `{:monitor_updated, monitor}` after the commit, like
  `update_monitor/2`, so their workers restart.
  """
  @spec put_labels([monitor_ref()], Labels.t() | [String.t()]) ::
          {:ok, [Monitor.t()]} | {:error, Ecto.Changeset.t()}
  def put_labels(monitors, labels) do
    case labels_changeset(%Monitor{}, labels) do
      %{valid?: true} = changeset ->
        labels = Ecto.Changeset.get_field(changeset, :labels)
        bulk_update(monitors, &labels_changeset(&1, Map.merge(&1.labels, labels)))

      changeset ->
        {:error, changeset}
    end
  end

  @doc """
  Removes the labels with the given keys (whatever their value) from each
  of the given monitors. Transaction and events as in `put_labels/2`.
  Automatic labels can't be removed: keys of automatic labels return an
  error changeset and change nothing.
  """
  @spec delete_labels([monitor_ref()], [Labels.key()]) ::
          {:ok, [Monitor.t()]} | {:error, Ecto.Changeset.t()}
  def delete_labels(monitors, keys) when is_list(keys) do
    keys = Enum.map(keys, &(&1 |> String.trim() |> String.downcase()))

    case Enum.filter(keys, &AutoLabels.reserved?/1) do
      [] -> bulk_update(monitors, &labels_changeset(&1, Map.drop(&1.labels, keys)))
      reserved -> {:error, labels_changeset(%Monitor{}, reserved)}
    end
  end

  defp labels_changeset(monitor, labels), do: Monitor.labels_changeset(monitor, labels)

  @doc """
  Enables (resumes) or disables (pauses) each of the given monitors.
  Transaction and events as in `put_labels/2`: only monitors that weren't
  already in that state change.
  """
  @spec set_monitors_enabled([monitor_ref()], boolean()) ::
          {:ok, [Monitor.t()]} | {:error, Ecto.Changeset.t()}
  def set_monitors_enabled(monitors, enabled) when is_boolean(enabled) do
    bulk_update(monitors, &Ecto.Changeset.change(&1, enabled: enabled))
  end

  @doc """
  Deletes the given monitors (structs or ids; unknown ids are ignored)
  together with their check results and incidents, in one statement.
  Returns the deleted monitors; each is broadcast as `{:monitor_deleted,
  monitor}`, like `delete_monitor/1`, and their remaining children as
  `{:monitor_updated, child}`.
  """
  @spec delete_monitors([monitor_ref()]) :: {:ok, [Monitor.t()]}
  def delete_monitors(monitors) do
    ids = Enum.map(monitors, &monitor_id/1)
    children = child_ids(ids)

    {_count, deleted} =
      Monitor
      |> where([m], m.id in ^ids)
      |> select([m], m)
      |> Repo.delete_all()

    Enum.each(deleted, &broadcast_monitor_change({:ok, &1}, :monitor_deleted))
    broadcast_detached(children)
    {:ok, deleted}
  end

  # Applies `change` (monitor -> changeset) to the given monitors in one
  # transaction and broadcasts the changed ones after the commit. Rows are
  # locked (in id order, so concurrent bulk changes can't deadlock) while
  # their labels are merged, so concurrent bulk changes don't overwrite
  # each other.
  defp bulk_update(monitors, change) do
    ids = Enum.map(monitors, &monitor_id/1)

    Repo.transaction(fn ->
      Monitor
      |> where([m], m.id in ^ids)
      |> order_by([m], asc: m.id)
      |> lock("FOR UPDATE")
      |> Repo.all()
      |> Enum.map(change)
      # An invalid cast leaves no change behind, but must still fail.
      |> Enum.reject(&(&1.valid? and &1.changes == %{}))
      |> Enum.map(&update_or_rollback/1)
    end)
    |> tap(fn
      {:ok, changed} -> Enum.each(changed, &broadcast_monitor_change({:ok, &1}, :monitor_updated))
      _error -> :ok
    end)
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, monitor} -> monitor
      {:error, changeset} -> Repo.rollback(changeset)
    end
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
  type, settings, schedule, description, labels and parent, named "<name>
  (copy)".

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
      parent_id: source.parent_id,
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

  ## Dependencies

  @doc """
  The ids of the monitors `monitor` depends on: its parent, the parent's
  parent and so on, nearest first (one recursive query).
  """
  @spec ancestor_ids(monitor_ref() | nil) :: [pos_integer()]
  def ancestor_ids(nil), do: []
  def ancestor_ids(monitor), do: monitor |> monitor_id() |> dependency_chain(:up) |> tl()

  @doc """
  The ids of the monitors that depend on `monitor`, directly or through
  other monitors, nearest first (one recursive query).
  """
  @spec descendant_ids(monitor_ref()) :: [pos_integer()]
  def descendant_ids(monitor), do: monitor |> monitor_id() |> dependency_chain(:down) |> tl()

  # The ids along the parent relation from `id` up (ancestors) or down
  # (descendants), starting with `id` (if it exists), nearest first. UNION
  # drops rows already found and the depth limit stops even on a cycle
  # (which can't be created, but still).
  defp dependency_chain(id, direction) do
    start =
      from(m in Monitor,
        where: m.id == ^id,
        select: %{id: m.id, parent_id: m.parent_id, depth: 0}
      )

    step =
      case direction do
        :up -> from(m in Monitor, join: c in "chain", on: m.id == c.parent_id)
        :down -> from(m in Monitor, join: c in "chain", on: m.parent_id == c.id)
      end
      |> where([_m, c], c.depth < @max_dependency_depth)
      |> select([m, c], %{id: m.id, parent_id: m.parent_id, depth: c.depth + 1})

    case {"chain", Monitor}
         |> recursive_ctes(true)
         |> with_cte("chain", as: ^union(start, ^step))
         |> group_by([c], c.id)
         |> order_by([c], asc: min(c.depth), asc: c.id)
         |> select([c], c.id)
         |> Repo.all() do
      [] -> [id]
      ids -> ids
    end
  end

  @doc """
  The monitors that have `monitor` as their parent, ordered by name.
  """
  @spec list_children(monitor_ref()) :: [Monitor.t()]
  def list_children(monitor) do
    id = monitor_id(monitor)

    Monitor
    |> where([m], m.parent_id == ^id)
    |> order_by([m], asc: fragment("lower(?)", m.name), asc: m.id)
    |> Repo.all()
  end

  @doc """
  Suggests a parent for `monitor` (saved or not): the ping or TCP monitor
  with the same automatic `host` label (see
  `Sentinelix.Monitoring.AutoLabels`), ping monitors first, then by name.

  Only a more basic type than the monitor's own is suggested (ping before
  TCP before all other types): ping monitors get no suggestion and TCP
  monitors only ping monitors. Never suggests the monitor itself or a
  monitor that depends on it. `nil` without a host or a candidate.
  """
  @spec suggest_parent(Monitor.t()) :: Monitor.t() | nil
  def suggest_parent(%Monitor{auto_labels: %{"host" => host}} = monitor) when is_binary(host) do
    case Enum.take_while(@parent_types, &(&1 != monitor.type)) do
      [] -> nil
      types -> suggest_parent(monitor, host, types)
    end
  end

  def suggest_parent(%Monitor{}), do: nil

  defp suggest_parent(monitor, host, types) do
    excluded = if monitor.id, do: [monitor.id | descendant_ids(monitor)], else: []

    Monitor
    |> where([m], m.type in ^types and m.id not in ^excluded)
    |> where([m], fragment("? @> ?", m.all_labels, ^%{"host" => host}))
    |> order_by([m], asc: m.type != ^:ping, asc: fragment("lower(?)", m.name), asc: m.id)
    |> limit(1)
    |> Repo.one()
  end

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
