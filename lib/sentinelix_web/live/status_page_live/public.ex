defmodule SentinelixWeb.StatusPageLive.Public do
  @moduledoc """
  A public status page (`/status/:slug`), reachable without logging in.

  Shows an overall banner, the page's groups with each monitor's current
  status and 90-day daily uptime bars, and the incidents of the last 7
  days. Unknown slugs and unpublished pages are a 404.

  Nothing but a monitor's display name and status is rendered unless the
  page enables `show_details` (targets and check/incident messages). The
  assigns only ever hold this sanitized data, never `%Monitor{}` structs.

  Updates arrive live: check results and incidents on the monitors' topics
  update single rows (the rows are keyed comprehensions, so only changed
  rows are sent), page configuration changes reload the page.

  Pages with selector groups also follow the `"monitors"` topic: when a
  monitor is created, relabelled, renamed or deleted so that a selector
  group gains, loses or reorders monitors, the page reloads. Reloads for
  monitor changes wait `:reload_delay_ms` (application environment of this
  module, default 500 ms) and are coalesced, so a bulk relabelling of
  many monitors reloads the page once. The selectors stay on the server:
  the page renders neither them nor labels.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents,
    only: [daily_uptime_bar: 1, format_duration: 1, format_uptime: 1, local_time: 1, target: 1]

  alias Sentinelix.{Maintenance, Monitoring, Stats, StatusPages}
  alias Sentinelix.Monitoring.History
  alias Sentinelix.StatusPages.Group

  @days 90
  @incident_days 7
  @reload_delay_ms Application.compile_env(:sentinelix, [__MODULE__, :reload_delay_ms], 500)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.public flash={@flash} title={@page.title}>
      <:footer :if={@page.footer_text}>{@page.footer_text}</:footer>

      <p
        :if={@page.description}
        id="page-description"
        class="whitespace-pre-line text-base-content/80"
      >
        {@page.description}
      </p>

      <div
        id="overall-status"
        data-status={@overall}
        class={["flex items-center gap-3 rounded-box px-5 py-4 font-semibold", banner_class(@overall)]}
      >
        <.icon name={banner_icon(@overall)} class="size-6 shrink-0" />
        <span class="text-lg">{banner_text(@overall)}</span>
      </div>

      <section :if={@maintenance != []} id="maintenance" class="space-y-2">
        <h2 class="px-1 text-sm font-semibold uppercase tracking-wide text-base-content/70">
          Maintenance
        </h2>
        <div class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
          <div
            :for={item <- @maintenance}
            :key={item.id}
            id={"maintenance-#{item.id}"}
            class="flex flex-col gap-1 px-4 py-3 sm:flex-row sm:items-center sm:gap-3"
          >
            <div class="min-w-0 flex-1">
              <div class="font-medium">{item.title}</div>
              <div class="text-xs text-base-content/60">
                <.local_time id={"maintenance-#{item.id}-start"} at={item.starts_at} /> –
                <.local_time id={"maintenance-#{item.id}-end"} at={item.ends_at} />
              </div>
              <div class="text-xs text-base-content/60">
                Affects: {Enum.join(item.monitor_names, ", ")}
              </div>
              <p :if={item.description} class="whitespace-pre-line text-xs text-base-content/60">
                {item.description}
              </p>
            </div>
            <span :if={item.active?} class="badge badge-info badge-sm">In progress</span>
            <span :if={!item.active?} class="badge badge-ghost badge-sm">Scheduled</span>
          </div>
        </div>
      </section>

      <p :if={@groups == []} id="no-monitors" class="text-center text-sm text-base-content/60">
        No services are listed on this page yet.
      </p>

      <section :for={group <- @groups} :key={group.id} id={"group-#{group.id}"} class="space-y-2">
        <h2 class="px-1 text-sm font-semibold uppercase tracking-wide text-base-content/70">
          {group.name}
        </h2>
        <div class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
          <p :if={group.rows == []} class="px-4 py-3 text-sm text-base-content/60">
            No services in this group.
          </p>
          <div
            :for={row <- group.rows}
            :key={row.id}
            id={"monitor-#{group.id}-#{row.id}"}
            data-status={row.status}
            class="space-y-2 px-4 py-3"
          >
            <div class="flex items-center gap-3">
              <div class="min-w-0 flex-1">
                <div class="truncate font-medium">{row.name}</div>
                <div :if={row.target} class="truncate text-xs text-base-content/60">
                  {row.target}
                </div>
              </div>
              <span
                class="text-sm tabular-nums text-base-content/60"
                title={"Uptime (#{days()} days)"}
              >
                {format_uptime(row.uptime)}
              </span>
              <.public_status_badge status={row.status} />
            </div>
            <.daily_uptime_bar id={"days-#{group.id}-#{row.id}"} days={row.days} />
            <p :if={row.message} class="truncate text-xs text-base-content/60">{row.message}</p>
          </div>
        </div>
        <div class="flex justify-between px-1 text-xs text-base-content/50">
          <span>{days()} days ago</span>
          <span>Today</span>
        </div>
      </section>

      <section :if={@groups != []} id="incidents" class="space-y-2">
        <h2 class="px-1 text-sm font-semibold uppercase tracking-wide text-base-content/70">
          Incidents (last {incident_days()} days)
        </h2>
        <div class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
          <p :if={@incidents == []} id="no-incidents" class="px-4 py-3 text-sm text-base-content/60">
            No incidents reported.
          </p>
          <div
            :for={incident <- @incidents}
            :key={incident.id}
            id={"incident-#{incident.id}"}
            class="flex flex-col gap-1 px-4 py-3 sm:flex-row sm:items-center sm:gap-3"
          >
            <div class="min-w-0 flex-1">
              <div class="truncate font-medium">{incident.monitor_name}</div>
              <div class="text-xs text-base-content/60">
                <.local_time id={"incident-#{incident.id}-start"} at={incident.started_at} />
                <span :if={incident.resolved_at}>
                  · resolved after {format_duration(
                    DateTime.diff(incident.resolved_at, incident.started_at)
                  )}
                </span>
              </div>
              <p :if={incident.message} class="truncate text-xs text-base-content/60">
                {incident.message}
              </p>
            </div>
            <span :if={is_nil(incident.resolved_at)} class="badge badge-error badge-sm">Ongoing</span>
            <span :if={incident.resolved_at} class="badge badge-ghost badge-sm">Resolved</span>
          </div>
        </div>
      </section>
    </Layouts.public>
    """
  end

  attr :status, :atom, required: true

  defp public_status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm w-24 justify-center gap-1.5 font-medium", status_class(@status)]}>
      <span class="inline-block size-1.5 rounded-full bg-current" />
      {status_label(@status)}
    </span>
    """
  end

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    page = StatusPages.get_published_status_page_by_slug!(slug)

    if connected?(socket) do
      StatusPages.subscribe(page)
      Maintenance.subscribe()
    end

    {:ok,
     socket
     |> assign(subscribed: MapSet.new(), monitors_subscribed?: false, reload_pending?: false)
     |> load(page)}
  end

  @impl true
  def handle_info({:check_result, result}, socket) do
    {:noreply,
     update_entry(socket, result.monitor_id, fn entry ->
       %{
         entry
         | latest_status: result.status,
           days: add_result(entry.days, result),
           message: details(socket, result.message)
       }
     end)}
  end

  def handle_info({event, %{monitor_id: id}}, socket)
      when event in [:incident_opened, :incident_resolved] do
    socket = update_entry(socket, id, &%{&1 | incident?: event == :incident_opened})
    {:noreply, load_incidents(socket)}
  end

  def handle_info({:monitor_created, monitor}, socket) do
    {:noreply, maybe_schedule_reload(socket, monitor)}
  end

  # Arrives on the monitor's topic for the page's monitors and, on pages
  # with selector groups, on the "monitors" topic for every monitor (so
  # twice for the page's monitors; both updates are idempotent).
  def handle_info({:monitor_updated, monitor}, socket) do
    {:noreply,
     socket
     |> maybe_schedule_reload(monitor)
     |> update_entry(monitor.id, fn entry ->
       %{
         entry
         | name: monitor.name,
           enabled: monitor.enabled,
           target: details(socket, target(monitor))
       }
     end)}
  end

  def handle_info({:maintenance_changed}, socket) do
    {:noreply, socket |> assign_maintenance() |> assign_view()}
  end

  def handle_info({:monitor_deleted, monitor}, socket) do
    if Map.has_key?(socket.assigns.entries, monitor.id),
      do: {:noreply, schedule_reload(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:reload, socket) do
    {:noreply, socket |> assign(reload_pending?: false) |> reload()}
  end

  def handle_info({event, _}, socket)
      when event in [:status_page_updated, :status_page_deleted] do
    {:noreply, reload(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Loading

  defp reload(socket) do
    %{id: id, slug: slug} = socket.assigns.page

    case StatusPages.get_status_page(id) do
      %{published: true, slug: ^slug} = page -> load(socket, page)
      %{published: true, slug: new_slug} -> redirect(socket, to: ~p"/status/#{new_slug}")
      # Gone or unpublished: the reload answers with a 404.
      _ -> redirect(socket, to: ~p"/status/#{slug}")
    end
  end

  defp load(socket, page) do
    monitors =
      page.groups
      |> Enum.flat_map(& &1.monitors)
      |> Enum.uniq_by(& &1.id)

    ids = Enum.map(monitors, & &1.id)
    latest = History.recent_results_by_monitor(1, ids)
    incidents = StatusPages.open_incident_monitor_ids(ids)
    days = Stats.daily_uptime(ids, @days)

    socket =
      socket
      |> assign(page: public_page(page), page_title: page.title)
      |> resubscribe(ids)
      |> assign_selector_groups(page.groups)

    entries =
      Map.new(monitors, fn monitor ->
        latest_result = latest |> Map.get(monitor.id, []) |> List.last()

        {monitor.id,
         %{
           id: monitor.id,
           name: monitor.name,
           enabled: monitor.enabled,
           latest_status: latest_result && latest_result.status,
           incident?: MapSet.member?(incidents, monitor.id),
           maintenance?: false,
           days: Map.get(days, monitor.id, []),
           target: details(socket, target(monitor)),
           message: details(socket, latest_result && latest_result.message)
         }}
      end)

    layout =
      Enum.map(page.groups, fn group ->
        %{
          id: group.id,
          name: group.name,
          monitor_ids: Enum.map(group.monitors, & &1.id)
        }
      end)

    socket
    |> assign(group_layout: layout, entries: entries)
    |> assign_maintenance()
    |> assign_view()
    |> load_incidents()
  end

  # Only what the page may show.
  defp public_page(page) do
    Map.take(page, [:id, :slug, :title, :description, :footer_text, :show_details])
  end

  defp details(socket, value) do
    if socket.assigns.page.show_details, do: value
  end

  defp resubscribe(socket, ids) do
    if connected?(socket) do
      new = MapSet.new(ids)
      old = socket.assigns.subscribed
      Enum.each(MapSet.difference(old, new), &Monitoring.unsubscribe_monitor/1)
      Enum.each(MapSet.difference(new, old), &Monitoring.subscribe_monitor/1)
      assign(socket, subscribed: new)
    else
      socket
    end
  end

  # What's needed to tell whether a monitor change changes the selector
  # groups: their selectors, pinned monitors (which stay where they are
  # whatever their labels) and the monitors they matched.
  defp assign_selector_groups(socket, groups) do
    selector_groups =
      for group <- groups, selector = Group.parsed_selector(group) do
        pinned = MapSet.new(group.page_monitors, & &1.monitor_id)

        %{
          selector: selector,
          pinned: pinned,
          matched:
            group.monitors |> Enum.map(& &1.id) |> MapSet.new() |> MapSet.difference(pinned)
        }
      end

    socket
    |> assign(selector_groups: selector_groups)
    |> subscribe_monitors(selector_groups != [])
  end

  # Stays subscribed when the page loses its selector groups: the events
  # are then ignored (see layout_changed?/2).
  defp subscribe_monitors(%{assigns: %{monitors_subscribed?: false}} = socket, true) do
    if connected?(socket) do
      Monitoring.subscribe_monitors()
      assign(socket, monitors_subscribed?: true)
    else
      socket
    end
  end

  defp subscribe_monitors(socket, _selector_groups?), do: socket

  defp maybe_schedule_reload(socket, monitor) do
    if layout_changed?(socket, monitor), do: schedule_reload(socket), else: socket
  end

  # Whether the monitor (as it is now) joins or leaves a selector group, or
  # is renamed while matched (the matches are ordered by name).
  defp layout_changed?(socket, monitor) do
    shown = Map.get(socket.assigns.entries, monitor.id)

    Enum.any?(socket.assigns.selector_groups, fn group ->
      matched? = MapSet.member?(group.matched, monitor.id)

      not MapSet.member?(group.pinned, monitor.id) and
        (StatusPages.member?(group.selector, monitor) != matched? or
           (matched? and shown.name != monitor.name))
    end)
  end

  defp schedule_reload(%{assigns: %{reload_pending?: true}} = socket), do: socket

  defp schedule_reload(socket) do
    if @reload_delay_ms == 0,
      do: send(self(), :reload),
      else: Process.send_after(self(), :reload, @reload_delay_ms)

    assign(socket, reload_pending?: true)
  end

  defp load_incidents(socket) do
    %{entries: entries} = socket.assigns
    since = DateTime.add(DateTime.utc_now(), -@incident_days * 86_400)

    incidents =
      entries
      |> Map.keys()
      |> StatusPages.recent_incidents(since)
      |> Enum.map(fn incident ->
        %{
          id: incident.id,
          monitor_name: entries[incident.monitor_id].name,
          started_at: incident.started_at,
          resolved_at: incident.resolved_at,
          message: details(socket, incident.message)
        }
      end)

    assign(socket, incidents: incidents)
  end

  # Active and upcoming maintenance windows (from the cache, no queries).
  defp assign_maintenance(socket) do
    %{entries: entries} = socket.assigns
    ids = Map.keys(entries)
    now = DateTime.utc_now()
    active = Maintenance.active_windows_for(ids, now)

    entries =
      Map.new(entries, fn {id, entry} ->
        {id, %{entry | maintenance?: Map.has_key?(active, id)}}
      end)

    maintenance =
      ids
      |> StatusPages.upcoming_maintenance(now)
      |> Enum.map(fn item ->
        %{
          id: item.window.id,
          title: item.window.title,
          description: details(socket, item.window.description),
          starts_at: item.starts_at,
          ends_at: item.ends_at,
          active?: item.active?,
          monitor_names: item.monitor_ids |> Enum.map(&entries[&1].name) |> Enum.sort()
        }
      end)

    assign(socket, entries: entries, maintenance: maintenance)
  end

  ## View state

  defp update_entry(socket, id, fun) do
    case Map.fetch(socket.assigns.entries, id) do
      {:ok, entry} ->
        socket
        |> assign(entries: Map.put(socket.assigns.entries, id, fun.(entry)))
        |> assign_view()

      :error ->
        socket
    end
  end

  # Derives the rendered rows and the banner from the entries.
  defp assign_view(socket) do
    rows =
      Map.new(socket.assigns.entries, fn {id, entry} ->
        {id,
         %{
           id: id,
           name: entry.name,
           status: StatusPages.public_status(entry),
           days: entry.days,
           uptime: total_uptime(entry.days),
           target: entry.target,
           message: entry.message
         }}
      end)

    groups =
      Enum.map(socket.assigns.group_layout, fn group ->
        %{id: group.id, name: group.name, rows: Enum.map(group.monitor_ids, &rows[&1])}
      end)

    overall = rows |> Map.values() |> Enum.map(& &1.status) |> StatusPages.overall_status()

    assign(socket, groups: groups, overall: overall)
  end

  # Counts a live check result into today's bar (starting a new day after
  # midnight UTC).
  defp add_result([_ | _] = days, %{status: status, checked_at: checked_at}) do
    date = DateTime.to_date(checked_at)
    today = List.last(days)

    case Date.compare(date, today.date) do
      :eq -> List.replace_at(days, -1, count_result(today, status))
      :gt -> tl(days) ++ [count_result(empty_day(date), status)]
      :lt -> days
    end
  end

  defp add_result(days, _result), do: days

  defp empty_day(date),
    do: %{date: date, uptime: nil, up: 0, down: 0, pending: 0, maintenance: 0, unreachable: 0}

  defp count_result(day, status) do
    day = Map.update!(day, status, &(&1 + 1))
    %{day | uptime: Stats.uptime_percent(day)}
  end

  defp total_uptime(days) do
    Stats.uptime_percent(%{
      up: Enum.sum_by(days, & &1.up),
      down: Enum.sum_by(days, & &1.down),
      unreachable: Enum.sum_by(days, & &1.unreachable)
    })
  end

  ## Presentation

  defp days, do: @days
  defp incident_days, do: @incident_days

  defp status_label(:operational), do: "Operational"
  defp status_label(:degraded), do: "Degraded"
  defp status_label(:outage), do: "Outage"
  defp status_label(:unreachable), do: "Unreachable"
  defp status_label(:maintenance), do: "Maintenance"
  defp status_label(:paused), do: "Paused"
  defp status_label(:unknown), do: "No data"

  defp status_class(:operational), do: "badge-success"
  defp status_class(:degraded), do: "badge-warning"
  defp status_class(:outage), do: "badge-error"
  defp status_class(:unreachable), do: "badge-error badge-soft"
  defp status_class(:maintenance), do: "badge-info"
  defp status_class(_status), do: "badge-ghost"

  defp banner_text(:operational), do: "All systems operational"
  defp banner_text(:degraded), do: "Degraded performance"
  defp banner_text(:partial_outage), do: "Partial outage"
  defp banner_text(:major_outage), do: "Major outage"
  defp banner_text(:maintenance), do: "Maintenance in progress"

  defp banner_class(:operational), do: "bg-success text-success-content"
  defp banner_class(:degraded), do: "bg-warning text-warning-content"
  defp banner_class(:partial_outage), do: "bg-warning text-warning-content"
  defp banner_class(:major_outage), do: "bg-error text-error-content"
  defp banner_class(:maintenance), do: "bg-info text-info-content"

  defp banner_icon(:operational), do: "hero-check-circle"
  defp banner_icon(:maintenance), do: "hero-wrench-screwdriver"
  defp banner_icon(_status), do: "hero-exclamation-triangle"
end
