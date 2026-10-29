defmodule Sentinelix.Notifications do
  @moduledoc """
  The Notifications context: notification channels, which monitors they are
  attached to, and sending notifications.

  `Sentinelix.Notifications.Dispatcher` listens to the monitoring engine's
  `"status_changes"` events and sends notifications to the enabled channels
  of a monitor (see its docs for when exactly). Providers are listed in
  `Sentinelix.Notifications.Provider`.

  ## PubSub

  Channel changes are broadcast on the `"notification_channels"` topic
  (`subscribe_channels/0`) as `{:channel_created | :channel_updated |
  :channel_deleted, %Channel{}}`.
  """

  import Ecto.Query, warn: false

  alias Phoenix.PubSub
  alias Sentinelix.Monitoring.Monitor
  alias Sentinelix.Notifications.{Channel, Delivery, Event, State}
  alias Sentinelix.Repo

  @pubsub Sentinelix.PubSub
  @channels_topic "notification_channels"
  @join_table "monitor_notification_channels"

  @type monitor_ref :: Monitor.t() | pos_integer()
  @type channel_ref :: Channel.t() | pos_integer()

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
  Returns the channels attached to a monitor, ordered by name.

  ## Options

    * `:enabled` – only return enabled (`true`) or disabled (`false`) channels
  """
  @spec list_channels_for_monitor(monitor_ref(), keyword()) :: [Channel.t()]
  def list_channels_for_monitor(monitor, opts \\ []) do
    id = id(monitor)

    Channel
    |> join(:inner, [c], mc in @join_table, on: mc.channel_id == c.id)
    |> where([_c, mc], mc.monitor_id == ^id)
    |> then(fn query ->
      case Keyword.fetch(opts, :enabled) do
        {:ok, enabled} -> where(query, [c], c.enabled == ^enabled)
        :error -> query
      end
    end)
    |> order_by([c], asc: fragment("lower(?)", c.name), asc: c.id)
    |> Repo.all()
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
  Returns a map of channel id => number of attached monitors (channels
  without monitors are missing).
  """
  @spec channel_monitor_counts() :: %{pos_integer() => pos_integer()}
  def channel_monitor_counts do
    from(mc in @join_table, group_by: mc.channel_id, select: {mc.channel_id, count()})
    |> Repo.all()
    |> Map.new()
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
