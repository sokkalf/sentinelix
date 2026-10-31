defmodule Sentinelix.Notifications do
  @moduledoc """
  The Notifications context: notification channels, which monitors they are
  attached to, and sending notifications.

  `Sentinelix.Notifications.Dispatcher` listens to the monitoring engine's
  `"status_changes"` events and sends notifications to the enabled channels
  of a monitor (see its docs for when exactly). Providers are listed in
  `Sentinelix.Notifications.Provider`.

  ## Routing

  The channels of a monitor are the channels **attached** to it (through
  the `monitor_notification_channels` join table, see
  `put_monitor_channels/2`) plus the channels whose **selector** matches it
  (see `Sentinelix.Notifications.Channel`). `list_routed_channels/2`
  resolves both, with the reason, from the monitor's labels and name as
  they are in the database when it is called. The dispatcher and
  `send_monitor_test_notification/2` send to the enabled ones
  (`list_notified_channels/1`), so a label change routes the next
  notification without restarting anything. A channel without a selector
  routes nothing by selector.

  ## PubSub

  Channel changes are broadcast on the `"notification_channels"` topic
  (`subscribe_channels/0`) as `{:channel_created | :channel_updated |
  :channel_deleted, %Channel{}}`.
  """

  import Ecto.Query, warn: false

  alias Phoenix.PubSub
  alias Sentinelix.Monitoring.{Monitor, Selector}
  alias Sentinelix.Notifications.{Channel, Delivery, Event, State}
  alias Sentinelix.Repo

  @pubsub Sentinelix.PubSub
  @channels_topic "notification_channels"
  @join_table "monitor_notification_channels"

  @type monitor_ref :: Monitor.t() | pos_integer()
  @type channel_ref :: Channel.t() | pos_integer()

  @typedoc """
  Why a channel notifies a monitor: it is attached to the monitor
  (`:explicit`), or its selector matches the monitor (`:selector`).
  """
  @type reason :: :explicit | :selector

  @typedoc "A channel with the reasons (one or both) it notifies a monitor."
  @type route :: {Channel.t(), [reason(), ...]}

  ## PubSub

  @doc """
  Subscribes the caller to channel changes.
  """
  def subscribe_channels, do: PubSub.subscribe(@pubsub, @channels_topic)

  defp broadcast({:ok, channel} = result, event) do
    PubSub.broadcast(@pubsub, @channels_topic, {event, channel})
    result
  end

  defp broadcast(error, _event), do: error

  ## Channels

  @doc """
  Returns all channels, ordered by name.
  """
  @spec list_channels() :: [Channel.t()]
  def list_channels do
    Channel
    |> order_by([c], asc: fragment("lower(?)", c.name), asc: c.id)
    |> Repo.all()
  end

  @doc """
  Gets a channel. Raises `Ecto.NoResultsError` if it does not exist.
  """
  @spec get_channel!(pos_integer()) :: Channel.t()
  def get_channel!(id), do: Repo.get!(Channel, id)

  @doc """
  Gets a channel, or `nil`.
  """
  @spec get_channel(pos_integer()) :: Channel.t() | nil
  def get_channel(id), do: Repo.get(Channel, id)

  @doc """
  Creates a channel.

      create_channel(%{name: "Ops", type: :slack, config: %{"webhook_url" => "https://..."}})
  """
  @spec create_channel(map()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def create_channel(attrs \\ %{}) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:channel_created)
  end

  @doc """
  Updates a channel. Blank secret config fields keep their stored value.
  """
  @spec update_channel(Channel.t(), map()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def update_channel(%Channel{} = channel, attrs) do
    channel
    |> Channel.changeset(attrs)
    |> Repo.update()
    |> broadcast(:channel_updated)
  end

  @doc """
  Deletes a channel (and detaches it from all monitors).
  """
  @spec delete_channel(Channel.t()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def delete_channel(%Channel{} = channel) do
    channel
    |> Repo.delete()
    |> broadcast(:channel_deleted)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking channel changes.
  """
  @spec change_channel(Channel.t(), map()) :: Ecto.Changeset.t()
  def change_channel(%Channel{} = channel, attrs \\ %{}), do: Channel.changeset(channel, attrs)

  ## Monitor <-> channel assignments

  @doc """
  Returns the channels attached to a monitor, ordered by name. Channels
  routed to it by selector are not included: see `list_routed_channels/2`
  for all channels that notify a monitor.

  ## Options

    * `:enabled` – only return enabled (`true`) or disabled (`false`) channels
  """
  @spec list_channels_for_monitor(monitor_ref(), keyword()) :: [Channel.t()]
  def list_channels_for_monitor(monitor, opts \\ []) do
    id = id(monitor)

    Channel
    |> join(:inner, [c], mc in @join_table, on: mc.channel_id == c.id)
    |> where([_c, mc], mc.monitor_id == ^id)
    |> filter_enabled(opts)
    |> order_by([c], asc: fragment("lower(?)", c.name), asc: c.id)
    |> Repo.all()
  end

  defp filter_enabled(query, opts) do
    case Keyword.fetch(opts, :enabled) do
      {:ok, enabled} -> where(query, [c], c.enabled == ^enabled)
      :error -> query
    end
  end

  @doc """
  Returns the ids of the channels attached to a monitor.
  """
  @spec monitor_channel_ids(monitor_ref()) :: [pos_integer()]
  def monitor_channel_ids(monitor) do
    id = id(monitor)

    from(mc in @join_table, where: mc.monitor_id == ^id, select: mc.channel_id)
    |> Repo.all()
  end

  @doc """
  Sets the channels of a monitor to exactly the given channels (ids or
  structs; unknown ids are ignored).
  """
  @spec put_monitor_channels(monitor_ref(), [channel_ref()]) :: :ok
  def put_monitor_channels(monitor, channels) do
    monitor_id = id(monitor)
    channel_ids = existing_ids(Channel, Enum.map(channels, &id/1))

    {:ok, :ok} =
      Repo.transaction(fn ->
        from(mc in @join_table, where: mc.monitor_id == ^monitor_id) |> Repo.delete_all()

        Repo.insert_all(
          @join_table,
          Enum.map(channel_ids, &%{monitor_id: monitor_id, channel_id: &1})
        )

        :ok
      end)

    :ok
  end

  @doc """
  Returns the ids of the monitors a channel is attached to.
  """
  @spec channel_monitor_ids(channel_ref()) :: [pos_integer()]
  def channel_monitor_ids(channel) do
    id = id(channel)

    from(mc in @join_table, where: mc.channel_id == ^id, select: mc.monitor_id)
    |> Repo.all()
  end

  @doc """
  Returns a map of channel id => number of monitors the channel notifies,
  attached or matched by its selector, each monitor counted once (channels
  without monitors are missing).
  """
  @spec channel_monitor_counts() :: %{pos_integer() => pos_integer()}
  def channel_monitor_counts do
    attached =
      from(mc in @join_table, group_by: mc.channel_id, select: {mc.channel_id, count()})
      |> Repo.all()
      |> Map.new()

    routed =
      for channel <- Repo.all(from(c in Channel, where: c.selector != "")),
          selector = Channel.parsed_selector(channel),
          selector != nil,
          count = count_routed_monitors(channel, selector),
          count > 0,
          into: %{},
          do: {channel.id, count}

    Map.merge(attached, routed)
  end

  defp count_routed_monitors(channel, selector) do
    attached = from(mc in @join_table, where: mc.channel_id == ^channel.id, select: mc.monitor_id)
    matches = Selector.to_dynamic(selector)
    condition = dynamic([m], m.id in subquery(attached) or ^matches)

    from(m in Monitor, where: ^condition, select: count()) |> Repo.one()
  end

  @doc """
  Returns the ids of the monitors a channel's selector matches (evaluated
  in the database), `[]` for a channel without a selector. The attached
  monitors are `channel_monitor_ids/1`.
  """
  @spec selector_monitor_ids(Channel.t()) :: [pos_integer()]
  def selector_monitor_ids(%Channel{} = channel) do
    case Channel.parsed_selector(channel) do
      nil -> []
      selector -> Monitor |> Selector.filter(selector) |> select([m], m.id) |> Repo.all()
    end
  end

  @doc """
  Attaches a channel to exactly the given monitors (ids or structs; unknown
  ids are ignored).
  """
  @spec put_channel_monitors(channel_ref(), [monitor_ref()]) :: :ok
  def put_channel_monitors(channel, monitors) do
    channel_id = id(channel)
    monitor_ids = existing_ids(Monitor, Enum.map(monitors, &id/1))

    {:ok, :ok} =
      Repo.transaction(fn ->
        from(mc in @join_table, where: mc.channel_id == ^channel_id) |> Repo.delete_all()

        Repo.insert_all(
          @join_table,
          Enum.map(monitor_ids, &%{monitor_id: &1, channel_id: channel_id})
        )

        :ok
      end)

    :ok
  end

  @doc """
  Attaches each of the given channels to each of the given monitors, in
  addition to the channels they already have (ids or structs; unknown ids
  are ignored). One statement, so all or nothing.

  Like the other assignment changes this restarts nothing: the dispatcher
  looks up a monitor's channels when it sends.
  """
  @spec attach_channels([monitor_ref()], [channel_ref()]) :: :ok
  def attach_channels(monitors, channels) do
    monitor_ids = existing_ids(Monitor, Enum.map(monitors, &id/1))
    channel_ids = existing_ids(Channel, Enum.map(channels, &id/1))

    rows = for m <- monitor_ids, c <- channel_ids, do: %{monitor_id: m, channel_id: c}
    Repo.insert_all(@join_table, rows, on_conflict: :nothing)
    :ok
  end

  @doc """
  Detaches each of the given channels from each of the given monitors.
  """
  @spec detach_channels([monitor_ref()], [channel_ref()]) :: :ok
  def detach_channels(monitors, channels) do
    monitor_ids = Enum.map(monitors, &id/1)
    channel_ids = Enum.map(channels, &id/1)

    from(mc in @join_table,
      where: mc.monitor_id in ^monitor_ids and mc.channel_id in ^channel_ids
    )
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Returns the default channels (those attached to new monitors).
  """
  @spec list_default_channels() :: [Channel.t()]
  def list_default_channels do
    Channel
    |> where([c], c.default)
    |> order_by([c], asc: fragment("lower(?)", c.name), asc: c.id)
    |> Repo.all()
  end

  @doc """
  Attaches all default channels to a monitor (in addition to the channels it
  already has). Called by `Sentinelix.Monitoring.create_monitor/1`.
  """
  @spec attach_default_channels(monitor_ref()) :: :ok
  def attach_default_channels(monitor) do
    monitor_id = id(monitor)

    rows =
      from(c in Channel,
        where: c.default,
        select: %{monitor_id: type(^monitor_id, :integer), channel_id: c.id}
      )

    Repo.insert_all(@join_table, rows, on_conflict: :nothing)
    :ok
  end

  ## Routing

  @doc """
  Returns the channels that notify a monitor, with the reasons, ordered by
  name: the channels attached to it and the channels whose selector
  matches it. The monitor's labels and name are read from the database
  now, so changes apply right away; a monitor that doesn't exist (any
  more) has no channels.

  This is the resolution notifications use, see `list_notified_channels/1`.

  ## Options

    * `:enabled` – only return enabled (`true`) or disabled (`false`) channels
  """
  @spec list_routed_channels(monitor_ref(), keyword()) :: [route()]
  def list_routed_channels(monitor, opts \\ []) do
    id = id(monitor)

    case Repo.get(Monitor, id) do
      nil ->
        []

      %Monitor{} = monitor ->
        attached_ids = monitor_channel_ids(id)

        Channel
        |> where([c], c.id in ^attached_ids or c.selector != "")
        |> filter_enabled(opts)
        |> order_by([c], asc: fragment("lower(?)", c.name), asc: c.id)
        |> Repo.all()
        |> route_channels(monitor, attached_ids)
    end
  end

  @doc """
  The enabled channels that notify a monitor (see `list_routed_channels/2`):
  where the dispatcher sends down, recovery and warning notifications and
  `send_monitor_test_notification/2` its test. Disabled channels never
  send.
  """
  @spec list_notified_channels(monitor_ref()) :: [Channel.t()]
  def list_notified_channels(monitor) do
    monitor
    |> list_routed_channels(enabled: true)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Routes `channels` to a monitor in memory, as `list_routed_channels/2`
  does with the database: each channel with the reasons it notifies the
  monitor, attached (its id is one of `attached_ids`) and/or matched by its
  selector (`Channel.routes?/2`). Channels with neither are left out; the
  order is kept.

  For monitors with unsaved changes, e.g. the monitor form showing where
  the labels being edited route notifications. `monitor` doesn't have to be
  saved (see `Sentinelix.Monitoring.Selector.matches?/3` for the labels it
  uses).
  """
  @spec route_channels([Channel.t()], map(), [pos_integer()]) :: [route()]
  def route_channels(channels, monitor, attached_ids) do
    attached = MapSet.new(attached_ids)

    for channel <- channels,
        reasons = reasons(channel, monitor, attached),
        reasons != [],
        do: {channel, reasons}
  end

  defp reasons(channel, monitor, attached) do
    explicit = if MapSet.member?(attached, channel.id), do: [:explicit], else: []
    selector = if Channel.routes?(channel, monitor), do: [:selector], else: []
    explicit ++ selector
  end

  defp existing_ids(_schema, []), do: []

  defp existing_ids(schema, ids) do
    from(s in schema, where: s.id in ^Enum.uniq(ids), select: s.id) |> Repo.all()
  end

  ## Sending

  @doc """
  Sends a test notification to a channel right away (one attempt).
  """
  @spec send_test_notification(Channel.t()) :: :ok | {:error, term()}
  def send_test_notification(%Channel{} = channel), do: Delivery.deliver(channel, Event.test())

  @doc """
  Sends a test notification about a monitor to the channels a real one
  would go to (`list_notified_channels/1`), one attempt each, in parallel.
  Returns each channel with its result, ordered by channel name; `[]` when
  no enabled channel notifies the monitor.

  ## Options

    * `:timeout` – how long a send may take, in milliseconds (default
      30 000); a send that takes longer is stopped and returns
      `{:error, :timeout}`
  """
  @spec send_monitor_test_notification(Monitor.t(), keyword()) ::
          [{Channel.t(), :ok | {:error, term()}}]
  def send_monitor_test_notification(%Monitor{} = monitor, opts \\ []) do
    event = Event.test(monitor)
    channels = list_notified_channels(monitor)

    results =
      Task.async_stream(channels, &Delivery.deliver(&1, event),
        timeout: Keyword.get(opts, :timeout, 30_000),
        on_timeout: :kill_task,
        max_concurrency: max(length(channels), 1)
      )

    Enum.zip_with(channels, results, fn
      channel, {:ok, result} -> {channel, result}
      channel, {:exit, :timeout} -> {channel, {:error, :timeout}}
      channel, {:exit, reason} -> {channel, {:error, reason}}
    end)
  end

  ## Notification state (used by the dispatcher)

  @doc false
  @spec get_state(monitor_ref()) :: State.t()
  def get_state(monitor) do
    id = id(monitor)
    Repo.get(State, id) || %State{monitor_id: id, status: nil, warning: false}
  end

  @doc false
  @spec put_state(State.t(), map()) :: {:ok, State.t()} | {:error, Ecto.Changeset.t()}
  def put_state(%State{} = state, changes) do
    state
    |> Ecto.Changeset.change(changes)
    |> Repo.insert_or_update()
  end

  defp id(%{id: id}) when is_integer(id), do: id
  defp id(id) when is_integer(id), do: id
end
