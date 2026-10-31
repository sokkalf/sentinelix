defmodule Sentinelix.Maintenance do
  @moduledoc """
  Maintenance windows: planned periods during which monitors don't alert.

  See `Sentinelix.Maintenance.Window` for the schedule (one-off, daily or
  weekly in a named time zone) and which monitors a window applies to (all,
  attached ones and those matching a label selector).

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
  `Sentinelix.Maintenance.Cache`, no database query per check. The engine
  passes the monitor struct, so a window's selector is evaluated on the
  monitor's current labels and name: a monitor created or relabeled to
  match is in maintenance from its first check.

  ## Push monitors

  Push monitors are treated like all others: during a window, received
  pushes and missed-push deadlines are both recorded as `:maintenance` and
  don't change the status. Every received push still restarts the deadline.
  A push that is still missing after the window ends is reported by the
  next deadline check (at most `interval_seconds` after the previous one)
  and alerts normally.

  ## PubSub

  `{:maintenance_changed}` is broadcast on the `"maintenance"` topic (see
  `subscribe/0`) when windows are created, updated or deleted, when a
  window starts or ends (checked every minute) and when monitor changes
  change the monitors matching a window's selector.
  """

  import Ecto.Query, warn: false

  alias Phoenix.PubSub
  alias Sentinelix.Maintenance.{Cache, Window}
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{Monitor, Selector}
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
  windows only. See `Sentinelix.Maintenance.Window.applies_to?/2` for how
  selectors are evaluated for a monitor struct and for an id.
  """
  @spec active?(Monitor.t() | pos_integer(), DateTime.t()) :: boolean()
  def active?(monitor, %DateTime{} = now)
      when is_struct(monitor, Monitor) or is_integer(monitor) do
    Enum.any?(Cache.windows(), &(Window.applies_to?(&1, monitor) and Window.active?(&1, now)))
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
  # The enabled windows with their monitor ids, parsed selectors and the ids
  # of the monitors matching them, for the cache.
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
    |> Enum.map(fn window ->
      %{
        window
        | monitor_ids: ids |> Map.get(window.id, []) |> Enum.sort(),
          parsed_selector: Window.parsed_selector(window)
      }
    end)
    |> put_selector_ids()
  end

  # Evaluates the selectors in memory, with the matcher the engine uses on
  # monitor structs; one query for all windows.
  defp put_selector_ids(windows) do
    if Enum.any?(windows, &selects?/1) do
      monitors =
        Repo.all(
          from m in Monitor,
            select: %{id: m.id, name: m.name, all_labels: m.all_labels},
            order_by: [asc: m.id]
        )

      Enum.map(windows, &put_matches(&1, monitors))
    else
      windows
    end
  end

  defp put_matches(window, monitors) do
    if selects?(window) do
      selector = window.parsed_selector
      %{window | selector_ids: for(m <- monitors, Selector.matches?(selector, m), do: m.id)}
    else
      window
    end
  end

  defp selects?(%Window{all_monitors: all, parsed_selector: selector}),
    do: not all and selector != nil

  @doc """
  The monitors a window's selector (a string or a parsed
  `Sentinelix.Monitoring.Selector`) matches now, ordered by name: none for
  an empty selector or one windows don't allow. For the preview in the
  window form.
  """
  @spec selector_monitors(String.t() | Selector.t()) :: [Monitor.t()]
  def selector_monitors(selector) when is_binary(selector) do
    case Selector.parse(selector, allow: Window.selector_allow()) do
      {:ok, selector} -> selector_monitors(selector)
      {:error, _error} -> []
    end
  end

  def selector_monitors(%Selector{} = selector) do
    case Selector.validate(selector, allow: Window.selector_allow()) do
      {:ok, selector} ->
        if Selector.empty?(selector), do: [], else: Monitoring.list_monitors(selector: selector)

      {:error, _error} ->
        []
    end
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
  monitors it applies to, in addition to those matching `:selector` (both
  are ignored with `all_monitors: true`).

      create_window(%{
        title: "Database upgrade",
        starts_at: ~U[2026-11-01 22:00:00Z],
        ends_at: ~U[2026-11-01 23:00:00Z],
        monitor_ids: [1, 2]
      })

      create_window(%{
        title: "Oslo network work",
        starts_at: ~U[2026-11-01 22:00:00Z],
        ends_at: ~U[2026-11-01 23:00:00Z],
        selector: "site=oslo"
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
end
