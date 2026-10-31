defmodule Sentinelix.StatusPages do
  @moduledoc """
  Public status pages: pages with ordered groups of monitors, shown without
  authentication at `/status/<slug>` when published.

  A group is a fixed list of monitors or chooses them by selector (see
  `Sentinelix.StatusPages.Group`). The functions that load a page fill
  each group's `monitors` with its monitors in display order: its own
  (pinned) monitors in their positions, then the other monitors its
  selector matches, by name (see `group_monitors/2`).

  ## PubSub events

  Every configuration change of a page (the page itself, its groups or its
  monitors) is broadcast on the page's topic (see `subscribe/1`) after it
  has been committed:

    * `{:status_page_updated, page_id}`
    * `{:status_page_deleted, page_id}`

  The events carry only the page id, so subscribers (including the public
  page) reload what they are allowed to show.

  Changes of monitors (creating, relabelling, renaming or deleting them)
  change the members of selector groups without an event here: pages with
  selector groups follow the Monitoring context's `"monitors"` topic (see
  `Sentinelix.Monitoring.subscribe_monitors/0`) and check `member?/2`.
  """

  import Ecto.Query, warn: false

  alias Phoenix.PubSub
  alias Sentinelix.Maintenance
  alias Sentinelix.Maintenance.Window
  alias Sentinelix.Monitoring.{Incident, Monitor, Selector}
  alias Sentinelix.Repo
  alias Sentinelix.StatusPages.{Group, PageMonitor, StatusPage}

  @pubsub Sentinelix.PubSub

  @type public_status ::
          :operational | :degraded | :outage | :unreachable | :maintenance | :paused | :unknown
  @type overall_status ::
          :operational | :degraded | :partial_outage | :major_outage | :maintenance

  ## PubSub

  @doc """
  Subscribes the caller to the configuration changes of a status page.
  """
  @spec subscribe(StatusPage.t() | pos_integer()) :: :ok | {:error, term()}
  def subscribe(page), do: PubSub.subscribe(@pubsub, topic(page))

  defp topic(%StatusPage{id: id}), do: topic(id)
  defp topic(id) when is_integer(id), do: "status_page:#{id}"

  defp broadcast_change(page_id, event \\ :status_page_updated) do
    PubSub.broadcast(@pubsub, topic(page_id), {event, page_id})
  end

  defp notify({:ok, _} = result, page_id) do
    broadcast_change(page_id)
    result
  end

  defp notify(error, _page_id), do: error

  ## Pages

  @doc """
  Returns all status pages ordered by title, each with the number of
  distinct monitors on it (in fixed lists, pinned or matched by
  selectors): `[%{page: %StatusPage{}, monitor_count: n}]`.
  """
  @spec list_status_pages() :: [%{page: StatusPage.t(), monitor_count: non_neg_integer()}]
  def list_status_pages do
    pages =
      StatusPage
      |> order_by([p], asc: fragment("lower(?)", p.title), asc: p.id)
      |> Repo.all()
      |> Repo.preload(groups: :page_monitors)

    # One query per distinct selector, however many groups use it.
    matched =
      pages
      |> Enum.flat_map(& &1.groups)
      |> Enum.map(&Group.parsed_selector/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(&{&1, matching_monitor_ids(&1)})

    Enum.map(pages, fn page ->
      count =
        page.groups
        |> Enum.flat_map(&group_monitor_ids(&1, matched))
        |> Enum.uniq()
        |> length()

      %{page: page, monitor_count: count}
    end)
  end

  defp group_monitor_ids(group, matched) do
    pinned = Enum.map(group.page_monitors, & &1.monitor_id)

    case Group.parsed_selector(group) do
      nil -> pinned
      selector -> pinned ++ Map.fetch!(matched, selector)
    end
  end

  defp matching_monitor_ids(selector) do
    Monitor |> Selector.filter(selector) |> select([m], m.id) |> Repo.all()
  end

  @doc """
  Gets a status page with its groups and their monitors (in order).
  Raises `Ecto.NoResultsError` if it does not exist.
  """
  @spec get_status_page!(pos_integer()) :: StatusPage.t()
  def get_status_page!(id) do
    StatusPage
    |> Repo.get!(id)
    |> preload_layout()
  end

  @doc """
  Gets a status page with its groups and their monitors, or `nil`.
  """
  @spec get_status_page(pos_integer()) :: StatusPage.t() | nil
  def get_status_page(id) do
    case Repo.get(StatusPage, id) do
      nil -> nil
      page -> preload_layout(page)
    end
  end

  @doc """
  Gets a **published** status page by its slug, with its groups and their
  monitors. Raises `Ecto.NoResultsError` (a 404) for unknown slugs and
  unpublished pages.
  """
  @spec get_published_status_page_by_slug!(String.t()) :: StatusPage.t()
  def get_published_status_page_by_slug!(slug) when is_binary(slug) do
    StatusPage
    |> where([p], p.slug == ^slug and p.published)
    |> Repo.one!()
    |> preload_layout()
  end

  defp preload_layout(page) do
    page = Repo.preload(page, groups: [page_monitors: :monitor])
    %{page | groups: Enum.map(page.groups, &%{&1 | monitors: group_monitors(&1)})}
  end

  @doc """
  The monitors of a group (with its `page_monitors` and their monitors
  preloaded) in display order: its own monitors in their positions, then,
  for a selector group, the other monitors the selector matches, by name.

  `candidates` are the monitors to match the selector against in memory,
  e.g. to preview a selector that isn't saved yet; without them the
  database is queried.
  """
  @spec group_monitors(Group.t(), [Monitor.t()] | nil) :: [Monitor.t()]
  def group_monitors(%Group{} = group, candidates \\ nil) do
    pinned = Enum.map(group.page_monitors, & &1.monitor)
    pinned_ids = MapSet.new(pinned, & &1.id)

    matched =
      group
      |> Group.parsed_selector()
      |> matching_monitors(candidates)
      |> Enum.reject(&MapSet.member?(pinned_ids, &1.id))

    pinned ++ matched
  end

  defp matching_monitors(nil, _candidates), do: []

  defp matching_monitors(selector, nil) do
    Monitor
    |> Selector.filter(selector)
    |> order_by([m], asc: fragment("lower(?)", m.name), asc: m.id)
    |> Repo.all()
  end

  defp matching_monitors(selector, candidates) do
    candidates
    |> Enum.filter(&Selector.matches?(selector, &1))
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
  end

  @doc """
  Whether a monitor is matched by the selector of a group (or a parsed
  group selector, see `Sentinelix.StatusPages.Group.parsed_selector/1`):
  always `false` for fixed lists, whose monitors are their
  `page_monitors`. Evaluated in memory on the monitor's labels and name,
  with the same result as the query that loads the group.
  """
  @spec member?(Group.t() | Selector.t() | nil, Monitor.t()) :: boolean()
  def member?(%Group{} = group, %Monitor{} = monitor),
    do: member?(Group.parsed_selector(group), monitor)

  def member?(nil, %Monitor{}), do: false

  def member?(%Selector{} = selector, %Monitor{} = monitor),
    do: Selector.matches?(selector, monitor)

  @doc """
  Creates a status page. A missing slug is derived from the title.
  """
  @spec create_status_page(map()) :: {:ok, StatusPage.t()} | {:error, Ecto.Changeset.t()}
  def create_status_page(attrs \\ %{}) do
    %StatusPage{}
    |> StatusPage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a status page.
  """
  @spec update_status_page(StatusPage.t(), map()) ::
          {:ok, StatusPage.t()} | {:error, Ecto.Changeset.t()}
  def update_status_page(%StatusPage{} = page, attrs) do
    page
    |> StatusPage.changeset(attrs)
    |> Repo.update()
    |> notify(page.id)
  end

  @doc """
  Deletes a status page with its groups.
  """
  @spec delete_status_page(StatusPage.t()) :: {:ok, StatusPage.t()} | {:error, Ecto.Changeset.t()}
  def delete_status_page(%StatusPage{} = page) do
    case Repo.delete(page) do
      {:ok, page} ->
        broadcast_change(page.id, :status_page_deleted)
        {:ok, page}

      error ->
        error
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking status page changes.
  """
  @spec change_status_page(StatusPage.t(), map()) :: Ecto.Changeset.t()
  def change_status_page(%StatusPage{} = page, attrs \\ %{}) do
    StatusPage.changeset(page, attrs)
  end

  ## Groups

  @doc """
  Gets a group of the given page, or `nil`.
  """
  @spec get_group(StatusPage.t(), pos_integer()) :: Group.t() | nil
  def get_group(%StatusPage{id: page_id}, id) do
    Repo.get_by(Group, id: id, status_page_id: page_id)
  end

  @doc """
  Adds a group at the end of a page.
  """
  @spec create_group(StatusPage.t(), map()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def create_group(%StatusPage{id: page_id}, attrs) do
    position = next_position(from(g in Group, where: g.status_page_id == ^page_id))

    %Group{status_page_id: page_id, position: position}
    |> Group.changeset(attrs)
    |> Repo.insert()
    |> notify(page_id)
  end

  @doc """
  Changes a group: its name, and whether it is a fixed list or a selector
  group (see `Sentinelix.StatusPages.Group.changeset/2`). Its monitors are
  kept: they become the pinned monitors of a selector group, or the list
  of a fixed one.
  """
  @spec update_group(Group.t(), map()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def update_group(%Group{} = group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update()
    |> notify(group.status_page_id)
  end

  @doc """
  Deletes a group (and removes its monitors from the page).
  """
  @spec delete_group(Group.t()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def delete_group(%Group{} = group) do
    group
    |> Repo.delete()
    |> notify(group.status_page_id)
  end

  @doc """
  Moves a group one position up or down within its page.
  """
  @spec move_group(Group.t(), :up | :down) :: :ok
  def move_group(%Group{} = group, direction) when direction in [:up, :down] do
    from(g in Group, where: g.status_page_id == ^group.status_page_id)
    |> move(group.id, direction)

    broadcast_change(group.status_page_id)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking group changes.
  """
  @spec change_group(Group.t(), map()) :: Ecto.Changeset.t()
  def change_group(%Group{} = group, attrs \\ %{}), do: Group.changeset(group, attrs)

  ## Monitors

  @doc """
  Gets a page monitor (a monitor's entry in a group) of the given page, or
  `nil`.
  """
  @spec get_page_monitor(StatusPage.t(), pos_integer()) :: PageMonitor.t() | nil
  def get_page_monitor(%StatusPage{id: page_id}, id) do
    PageMonitor
    |> join(:inner, [pm], g in assoc(pm, :group))
    |> where([pm, g], pm.id == ^id and g.status_page_id == ^page_id)
    |> preload([_pm, g], group: g)
    |> Repo.one()
  end

  @doc """
  Adds a monitor at the end of a group's own monitors. In a selector group
  this pins it: after the other pinned monitors, before those the selector
  matches.
  """
  @spec add_monitor(Group.t(), Monitor.t() | pos_integer()) ::
          {:ok, PageMonitor.t()} | {:error, Ecto.Changeset.t()}
  def add_monitor(%Group{} = group, monitor) do
    position = next_position(from(pm in PageMonitor, where: pm.group_id == ^group.id))

    %PageMonitor{group_id: group.id, position: position}
    |> PageMonitor.changeset(%{monitor_id: monitor_id(monitor)})
    |> Repo.insert()
    |> notify(group.status_page_id)
  end

  @doc """
  Removes a monitor from its group's own monitors. In a selector group this
  unpins it: it stays in the group while the selector matches it.
  """
  @spec remove_monitor(PageMonitor.t()) :: {:ok, PageMonitor.t()} | {:error, Ecto.Changeset.t()}
  def remove_monitor(%PageMonitor{} = page_monitor) do
    page_id = page_id_of(page_monitor)

    page_monitor
    |> Repo.delete()
    |> notify(page_id)
  end

  @doc """
  Moves a monitor one position up or down within its group.
  """
  @spec move_monitor(PageMonitor.t(), :up | :down) :: :ok
  def move_monitor(%PageMonitor{} = page_monitor, direction) when direction in [:up, :down] do
    from(pm in PageMonitor, where: pm.group_id == ^page_monitor.group_id)
    |> move(page_monitor.id, direction)

    broadcast_change(page_id_of(page_monitor))
  end

  defp page_id_of(%PageMonitor{group: %Group{status_page_id: page_id}}), do: page_id

  defp page_id_of(%PageMonitor{group_id: group_id}) do
    Repo.one!(from g in Group, where: g.id == ^group_id, select: g.status_page_id)
  end

  ## Ordering

  defp next_position(siblings) do
    (Repo.one(from s in siblings, select: max(s.position)) || -1) + 1
  end

  # Swaps the item with its neighbour and renumbers all siblings 0..n-1,
  # which also heals gaps and duplicate positions.
  defp move(siblings, id, direction) do
    Repo.transaction(fn ->
      ids =
        siblings
        |> order_by([s], asc: s.position, asc: s.id)
        |> select([s], s.id)
        |> lock("FOR UPDATE")
        |> Repo.all()

      ids
      |> swap(id, direction)
      |> Enum.with_index()
      |> Enum.each(fn {sibling_id, position} ->
        Repo.update_all(from(s in siblings, where: s.id == ^sibling_id),
          set: [position: position]
        )
      end)
    end)

    :ok
  end

  defp swap(ids, id, direction) do
    index = Enum.find_index(ids, &(&1 == id))
    target = index && if(direction == :up, do: index - 1, else: index + 1)

    if index && target >= 0 && target < length(ids) do
      ids
      |> List.replace_at(index, Enum.at(ids, target))
      |> List.replace_at(target, id)
    else
      ids
    end
  end

  ## Public page data

  @doc """
  The ids of the given monitors that have an open incident.
  """
  @spec open_incident_monitor_ids([pos_integer()]) :: MapSet.t(pos_integer())
  def open_incident_monitor_ids(monitor_ids) do
    Incident
    |> where([i], i.monitor_id in ^monitor_ids and is_nil(i.resolved_at))
    |> select([i], i.monitor_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  The incidents of the given monitors that were open at some point since
  `since`, most recent first.
  """
  @spec recent_incidents([pos_integer()], DateTime.t(), pos_integer()) :: [Incident.t()]
  def recent_incidents(monitor_ids, %DateTime{} = since, limit \\ 50) do
    Incident
    |> where([i], i.monitor_id in ^monitor_ids)
    |> where([i], is_nil(i.resolved_at) or i.resolved_at >= ^since)
    |> order_by([i], desc: i.started_at, desc: i.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  The active and upcoming maintenance of the given monitors: one entry per
  enabled window that applies to at least one of them and is active at
  `now` or starts within `horizon_days`, ordered by start.

  Each entry is `%{window: %Window{}, starts_at:, ends_at:, active?:,
  monitor_ids:}` with the occurrence (UTC) and the ids of the given monitors
  the window applies to. Reads the cached windows only (no database query).
  """
  @spec upcoming_maintenance([pos_integer()], DateTime.t(), pos_integer()) :: [map()]
  def upcoming_maintenance(monitor_ids, %DateTime{} = now, horizon_days \\ 7) do
    horizon = DateTime.add(now, horizon_days * 86_400)

    for window <- Maintenance.Cache.windows(),
        ids = Enum.filter(monitor_ids, &Window.applies_to?(window, &1)),
        ids != [],
        {starts_at, ends_at} <- [Window.next_occurrence(window, now)],
        DateTime.compare(starts_at, horizon) != :gt do
      %{
        window: window,
        starts_at: starts_at,
        ends_at: ends_at,
        active?: DateTime.compare(starts_at, now) != :gt,
        monitor_ids: ids
      }
    end
    |> Enum.sort_by(&{DateTime.to_unix(&1.starts_at), &1.window.id})
  end

  @doc """
  The status of a monitor as shown on a public page, from a map with

    * `:enabled` – whether the monitor is enabled
    * `:latest_status` – the status of its latest check result (or `nil`)
    * `:incident?` – whether it has an open incident
    * `:maintenance?` – whether it is in a maintenance window (optional)

  Returns

    * `:paused` – the monitor is disabled
    * `:maintenance` – it is in maintenance (or its latest result is a
      maintenance result)
    * `:outage` – its latest check failed
    * `:unreachable` – its latest check failed while the monitor it
      depends on was down (counts as an outage for the page)
    * `:degraded` – a failed check is being retried (`:pending`), or it has
      an open incident while its latest check succeeded
    * `:operational` – its latest check succeeded
    * `:unknown` – no checks yet
  """
  @spec public_status(map()) :: public_status()
  def public_status(%{enabled: false}), do: :paused

  def public_status(%{latest_status: latest, incident?: incident?} = state) do
    cond do
      Map.get(state, :maintenance?, false) or latest == :maintenance -> :maintenance
      latest == :down -> :outage
      latest == :unreachable -> :unreachable
      latest == :pending or incident? -> :degraded
      latest == :up -> :operational
      true -> :unknown
    end
  end

  @doc """
  The overall status of a page from the public statuses of its monitors.

  Paused monitors and monitors without data are ignored and monitors in
  maintenance never count as an outage. When every remaining monitor is
  down (or unreachable) it is a major outage, when some are a partial
  outage.
  """
  @spec overall_status([public_status()]) :: overall_status()
  def overall_status(statuses) do
    counted = Enum.reject(statuses, &(&1 in [:paused, :unknown]))

    active =
      counted
      |> Enum.reject(&(&1 == :maintenance))
      |> Enum.map(&if(&1 == :unreachable, do: :outage, else: &1))

    cond do
      active != [] and Enum.all?(active, &(&1 == :outage)) -> :major_outage
      :outage in active -> :partial_outage
      :degraded in active -> :degraded
      :maintenance in counted -> :maintenance
      true -> :operational
    end
  end

  defp monitor_id(%Monitor{id: id}), do: id
  defp monitor_id(id) when is_integer(id), do: id
end
