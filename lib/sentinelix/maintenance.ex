defmodule Sentinelix.Maintenance do
  @moduledoc """
  Maintenance windows: planned periods during which monitors don't alert.

  See `Sentinelix.Maintenance.Window` for the schedule (one-off, daily or
  weekly in a named time zone) and which monitors a window applies to.

  ## Engine integration

  The monitoring engine is configured with this module as its maintenance
  module (`config :sentinelix, Sentinelix.Monitoring.Supervisor,
  maintenance: Sentinelix.Maintenance`) and calls `active?/2` after every
  check. While it returns `true`, checks still run but their results are
  recorded with status `:maintenance`; the worker's status, retries and
  incidents are left untouched and no status events are broadcast, so no
  notifications are sent. With the first check after the window normal
  evaluation resumes: a monitor that went down during the window goes down
  (after its retries) and is notified like any other outage, while one that
  was already down and notified before the window isn't notified again (the
  notification dispatcher remembers the last notified status).

  `active?/2` only reads the windows cached by
  `Sentinelix.Maintenance.Cache`, no database query per check.

  ## Push monitors

  Push monitors are treated like all others: during a window, received
  pushes and missed-push deadlines are both recorded as `:maintenance` and
  don't change the status. Every received push still restarts the deadline.
  A push that is still missing after the window ends is reported by the
  next deadline check (at most `interval_seconds` after the previous one)
  and alerts normally.

  ## PubSub

  `{:maintenance_changed}` is broadcast on the `"maintenance"` topic (see
  `subscribe/0`) when windows are created, updated or deleted and when a
  window starts or ends (checked every minute).
  """

  import Ecto.Query, warn: false

  alias Phoenix.PubSub
  alias Sentinelix.Maintenance.{Cache, Window}
  alias Sentinelix.Monitoring.Monitor
  alias Sentinelix.Repo

  @pubsub Sentinelix.PubSub
  @topic "maintenance"

  ## PubSub

  @doc """
  Subscribes the caller to `{:maintenance_changed}` events.
  """
  def subscribe, do: PubSub.subscribe(@pubsub, @topic)

  @doc false
  def broadcast_changed, do: PubSub.broadcast(@pubsub, @topic, {:maintenance_changed})

  ## Engine and status queries (cached)

  @doc """
  Whether `monitor` is in an active maintenance window at `now`.

  Called by the monitoring engine after every check; uses the cached
  windows only.
  """
  @spec active?(Monitor.t() | pos_integer(), DateTime.t()) :: boolean()
  def active?(monitor, %DateTime{} = now) do
    id = monitor_id(monitor)
    Enum.any?(Cache.windows(), &(Window.applies_to?(&1, id) and Window.active?(&1, now)))
  end

  @doc """
  The windows active at `now`.
  """
  @spec active_windows(DateTime.t()) :: [Window.t()]
  def active_windows(%DateTime{} = now \\ DateTime.utc_now()) do
    Enum.filter(Cache.windows(), &Window.active?(&1, now))
  end

  @doc """
  The active windows at `now` of the given monitors, as a map of monitor id
  => windows. Monitors without an active window are left out.

  For pages that show maintenance badges (dashboard, monitor pages, status
  pages); uses the cached windows only.
  """
  @spec active_windows_for([pos_integer()], DateTime.t()) :: %{pos_integer() => [Window.t()]}
  def active_windows_for(monitor_ids, %DateTime{} = now \\ DateTime.utc_now()) do
    case active_windows(now) do
      [] ->
        %{}

      windows ->
        for id <- monitor_ids,
            matching = Enum.filter(windows, &Window.applies_to?(&1, id)),
            matching != [],
            into: %{},
            do: {id, matching}
    end
  end

  @doc false
  # The enabled windows with their monitor ids, for the cache.
  def load_windows do
    ids =
      from(wm in "maintenance_window_monitors",
        select: {wm.maintenance_window_id, wm.monitor_id}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Window
    |> where([w], w.enabled)
    |> order_by([w], asc: w.id)
    |> Repo.all()
    |> Enum.map(&%{&1 | monitor_ids: ids |> Map.get(&1.id, []) |> Enum.sort()})
  end

  ## CRUD

  @doc """
  Returns all windows with their monitors, ordered by title.
  """
  @spec list_windows() :: [Window.t()]
  def list_windows do
    Window
    |> order_by([w], asc: fragment("lower(?)", w.title), asc: w.id)
    |> preload(:monitors)
    |> Repo.all()
  end

  @doc """
  Gets a window with its monitors, or `nil`.
  """
  @spec get_window(pos_integer()) :: Window.t() | nil
  def get_window(id), do: Window |> Repo.get(id) |> Repo.preload(:monitors)

  @doc """
  Gets a window with its monitors. Raises if it doesn't exist.
  """
  @spec get_window!(pos_integer()) :: Window.t()
  def get_window!(id), do: Window |> Repo.get!(id) |> Repo.preload(:monitors)

  @doc """
  Creates a window. `:monitor_ids` (or `"monitor_ids"`) in `attrs` are the
  monitors it applies to (ignored with `all_monitors: true`).

      create_window(%{
        title: "Database upgrade",
        starts_at: ~U[2026-11-01 22:00:00Z],
        ends_at: ~U[2026-11-01 23:00:00Z],
        monitor_ids: [1, 2]
      })
  """
  @spec create_window(map()) :: {:ok, Window.t()} | {:error, Ecto.Changeset.t()}
  def create_window(attrs \\ %{}) do
    new_window()
    |> Window.changeset(attrs, monitors(attrs) || [])
    |> Repo.insert()
    |> refreshed()
  end

  @doc """
  A new, unsaved window in the default time zone (`default_timezone/0`).
  """
  @spec new_window() :: Window.t()
  def new_window, do: %Window{monitors: [], timezone: default_timezone()}

  @doc """
  The time zone new windows start out in: `config :sentinelix,
  :default_timezone` (`DEFAULT_TIMEZONE` in production), falling back to
  `Etc/UTC` if it isn't set or not a known time zone.
  """
  @spec default_timezone(String.t() | nil) :: String.t()
  def default_timezone(tz \\ Application.get_env(:sentinelix, :default_timezone)) do
    if Window.valid_timezone?(tz), do: tz, else: "Etc/UTC"
  end

  @doc """
  Updates a window. Replaces its monitors if `attrs` has `:monitor_ids`.
  """
  @spec update_window(Window.t(), map()) :: {:ok, Window.t()} | {:error, Ecto.Changeset.t()}
  def update_window(%Window{} = window, attrs) do
    window
    |> Repo.preload(:monitors)
    |> Window.changeset(attrs, monitors(attrs))
    |> Repo.update()
    |> refreshed()
  end

  @doc """
  Deletes a window.
  """
  @spec delete_window(Window.t()) :: {:ok, Window.t()} | {:error, Ecto.Changeset.t()}
  def delete_window(%Window{} = window) do
    window
    |> Repo.delete()
    |> refreshed()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking window changes.
  """
  @spec change_window(Window.t(), map()) :: Ecto.Changeset.t()
  def change_window(%Window{} = window, attrs \\ %{}) do
    window = Repo.preload(window, :monitors)
    Window.changeset(window, attrs, monitors(attrs))
  end

  defp monitors(attrs) do
    case Map.get(attrs, :monitor_ids, Map.get(attrs, "monitor_ids")) do
      nil ->
        nil

      ids ->
        ids = ids |> List.wrap() |> Enum.flat_map(&parse_id/1)
        Repo.all(from m in Monitor, where: m.id in ^ids, order_by: [asc: m.id])
    end
  end

  defp parse_id(id) when is_integer(id), do: [id]

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> [id]
      _ -> []
    end
  end

  defp parse_id(_id), do: []

  defp refreshed({:ok, _window} = result) do
    :ok = Cache.refresh()
    result
  end

  defp refreshed(error), do: error

  defp monitor_id(%Monitor{id: id}), do: id
  defp monitor_id(id) when is_integer(id), do: id
end
