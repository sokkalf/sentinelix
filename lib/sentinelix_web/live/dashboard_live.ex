defmodule SentinelixWeb.DashboardLive do
  @moduledoc """
  The dashboard: status counters and all monitors with their current
  status, a heartbeat bar of the latest checks, the 24h uptime and the
  latest response time. Updates in real time.

  The LiveView keeps a small index (monitor, status and 24h check counts
  per id) for the counters, filtering and grouping. The rows are streams
  in `SentinelixWeb.DashboardLive.Rows` components, one per group, which
  only re-render the rows that changed: a check result re-renders one row
  and the headers of its groups.

  ## The view

  What is shown is a `Sentinelix.Monitoring.View` kept in the URL
  (`?selector=env=prod&group=service,site&sort=name&layout=grid`):

    * The **selector** (`Sentinelix.Monitoring.Selector`) is evaluated on
      the index, with the status shown, so rows come and go as statuses
      change. The status counters toggle a `status=` term, label badges add
      a term. Links from before selectors keep working, see the view.
    * **Group by** one label key or two (nested), automatic ones included,
      with `Sentinelix.Monitoring.Grouping`. Each group has a header with
      its worst status, counts and 24h uptime.
    * **Sort** orders the groups: problems first (default) or by name.
    * The **layout**: a list of rows (default), a grid of small tiles
      (`SentinelixWeb.MonitorComponents.monitor_tile/1`, streamed by the
      same `Rows` components, so grouping and collapsing work the same) or
      a matrix of the two group-by keys
      (`SentinelixWeb.DashboardLive.Matrix`). The matrix asks for the keys
      while fewer than two are chosen.

  ## Expanded groups

  Groups with problems (down, unreachable or pending) are expanded, the
  others collapsed; a collapsed group renders no rows. Expanding or
  collapsing a group overrides that until the group's problem state
  changes (a group collapsed while red expands again when it turns red
  after recovering). The overrides are kept in the browser's
  `sessionStorage` (pushed with the `dashboard:groups` event) and sent
  back as the `dashboard_groups` connect parameter, so they survive
  reloads and reconnects for the session.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents
  import SentinelixWeb.SelectorComponents

  alias Sentinelix.{Maintenance, Monitoring, Stats}
  alias Sentinelix.Monitoring.{Grouping, Selector, View}
  alias SentinelixWeb.DashboardLive.{Matrix, Rows}

  @uptime_window {24, :hour}
  @statuses ~w(up down pending unreachable maintenance paused)a
  @max_overrides 500
  @layouts [list: "List", grid: "Grid", matrix: "Matrix"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:dashboard}>
      <.header>
        Dashboard
        <:subtitle>Live status of all monitors</:subtitle>
        <:actions>
          <.button navigate={~p"/monitors/new"} variant="primary" id="new-monitor">
            <.icon name="hero-plus" class="size-4" /> Add monitor
          </.button>
        </:actions>
      </.header>

      <div id="status-counters" class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
        <.link
          :for={status <- @statuses}
          id={"counter-#{status}"}
          patch={view_path(%{@view | selector: toggle_status(@view.selector, status)})}
          class={[
            "rounded-box border bg-base-100 p-4 transition hover:border-base-content/30",
            if(status_selected?(@view.selector, status),
              do: "border-base-content/40 ring-1 ring-base-content/20",
              else: "border-base-300"
            )
          ]}
        >
          <div class="flex items-center gap-2 text-xs font-medium uppercase tracking-wide text-base-content/60">
            <span class={["size-2 rounded-full bg-current", status_text_class(status)]} />
            {status_label(status)}
          </div>
          <div class={["mt-1 text-3xl font-semibold tabular-nums", count_class(status, @counts)]}>
            {@counts[status]}
          </div>
        </.link>
      </div>

      <div
        :if={@total == 0}
        id="empty-state"
        class="rounded-box border border-dashed border-base-300 bg-base-100 px-6 py-16 text-center"
      >
        <.icon name="hero-signal" class="mx-auto size-10 text-base-content/30" />
        <h3 class="mt-3 text-lg font-semibold">No monitors yet</h3>
        <p class="mt-1 text-sm text-base-content/60">
          Add your first monitor to start tracking uptime and response times.
        </p>
        <.button navigate={~p"/monitors/new"} variant="primary" class="btn btn-primary mt-6">
          <.icon name="hero-plus" class="size-4" /> Add monitor
        </.button>
      </div>

      <div :if={@total > 0} class="rounded-box border border-base-300 bg-base-100">
        <form
          id="filter-form"
          phx-change="filter"
          phx-submit="filter"
          class="flex flex-wrap items-start gap-2 border-b border-base-300 p-3"
        >
          <.selector_input
            id="selector"
            value={@selector_text}
            error={@selector_error}
            suggestions={@suggestions}
            class="min-w-64 flex-1 sm:max-w-xl"
          />
          <select id="layout" name="layout" aria-label="Layout" class="select select-sm w-auto">
            <option
              :for={{layout, label} <- @layouts}
              value={layout}
              selected={layout == @view.layout}
            >
              {label}
            </option>
          </select>
          <.group_by_select
            id="group-by-0"
            label={if @view.layout == :matrix, do: "Rows by", else: "Group by"}
            empty={if @view.layout == :matrix, do: "Rows by…", else: "No grouping"}
            value={Enum.at(@view.group_by, 0)}
            keys={@group_keys}
          />
          <.group_by_select
            :if={View.grouped?(@view)}
            id="group-by-1"
            label={if @view.layout == :matrix, do: "columns by", else: "then by"}
            empty={if @view.layout == :matrix, do: "Columns by…", else: "No nesting"}
            value={Enum.at(@view.group_by, 1)}
            keys={@group_keys -- Enum.take(@view.group_by, 1)}
          />
          <select
            :if={View.grouped?(@view)}
            id="sort"
            name="sort"
            aria-label={if @view.layout == :matrix, do: "Sort rows", else: "Sort groups"}
            class="select select-sm w-auto"
          >
            <option value="problems" selected={@view.sort == :problems}>Problems first</option>
            <option value="name" selected={@view.sort == :name}>By name</option>
          </select>
          <.link
            :if={@selector_text != ""}
            patch={view_path(%{@view | selector: %Selector{}})}
            class="btn btn-ghost btn-sm"
            id="clear-filters"
          >
            Clear
          </.link>
        </form>

        <div
          :if={View.grouped?(@view) and @view.layout != :matrix and @groups != []}
          class="flex items-center justify-end gap-1 border-b border-base-300 px-3 py-1"
        >
          <button type="button" id="expand-all" phx-click="expand_all" class="btn btn-ghost btn-xs">
            Expand all
          </button>
          <button
            type="button"
            id="collapse-all"
            phx-click="collapse_all"
            class="btn btn-ghost btn-xs"
          >
            Collapse all
          </button>
        </div>

        <div
          :if={@groups == []}
          id="monitors-empty"
          class="px-6 py-10 text-center text-sm text-base-content/60"
        >
          No monitors match your filters.
        </div>

        <div
          :if={@view.layout == :matrix and not View.matrix?(@view)}
          id="matrix-prompt"
          class="px-6 py-10 text-center text-sm text-base-content/60"
        >
          <.icon name="hero-table-cells" class="mx-auto size-8 text-base-content/30" />
          <p class="mt-2">
            The matrix shows one label key as rows and another as columns, e.g.
            <span class="font-mono">service</span>
            × <span class="font-mono">site</span>.
          </p>
          <p>
            Choose
            <label for={if View.grouped?(@view), do: "group-by-1", else: "group-by-0"} class="link">
              {if View.grouped?(@view), do: "a key for the columns", else: "a key for the rows"}
            </label>
            above.
          </p>
        </div>

        <Matrix.matrix
          :if={View.matrix?(@view) and @groups != []}
          id="matrix"
          rows={@groups}
          columns={@columns}
          view={@view}
        />

        <div
          :if={View.grouped?(@view) and @view.layout != :matrix}
          id="groups"
          class="divide-y divide-base-300"
        >
          <.group_section
            :for={group <- @groups}
            :key={group.id}
            group={group}
            overrides={@overrides}
            view={@view}
          />
        </div>

        <.live_component
          :for={group <- @groups}
          :if={not View.grouped?(@view) and @view.layout != :matrix}
          module={Rows}
          id="rows"
          dom_id="monitors"
          entries={group.entries}
          view={@view}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :empty, :string, required: true
  attr :value, :string, default: nil
  attr :keys, :list, required: true

  defp group_by_select(assigns) do
    ~H"""
    <select id={@id} name="group[]" aria-label={@label} class="select select-sm w-auto">
      <option value="">{@empty}</option>
      <option :for={key <- @keys} value={key} selected={key == @value}>
        {@label} {key}
      </option>
    </select>
    """
  end

  attr :group, Grouping.Group, required: true
  attr :overrides, :map, required: true
  attr :view, View, required: true
  attr :level, :integer, default: 0

  defp group_section(assigns) do
    assigns =
      assign(assigns,
        open: expanded?(assigns.overrides, assigns.group),
        dom_id: group_dom_id(assigns.group)
      )

    ~H"""
    <section id={@dom_id} data-group={@group.id} data-open={to_string(@open)}>
      <.group_header group={@group} open={@open} level={@level} dom_id={@dom_id} />
      <div :if={@open} id={@dom_id <> "-body"} class="border-t border-base-300">
        <div :if={@group.groups != []} class="divide-y divide-base-300">
          <.group_section
            :for={child <- @group.groups}
            :key={child.id}
            group={child}
            overrides={@overrides}
            view={@view}
            level={@level + 1}
          />
        </div>
        <.live_component
          :if={@group.groups == []}
          module={Rows}
          id={@dom_id <> "-rows"}
          dom_id={@dom_id <> "-rows"}
          entries={@group.entries}
          view={@view}
        />
      </div>
    </section>
    """
  end

  attr :group, Grouping.Group, required: true
  attr :open, :boolean, required: true
  attr :level, :integer, required: true
  attr :dom_id, :string, required: true

  defp group_header(assigns) do
    assigns =
      assign(assigns,
        others: Enum.filter(Grouping.severity(), &(&1 != :up and assigns.group.counts[&1] > 0))
      )

    ~H"""
    <div class={[
      "flex flex-wrap items-center gap-x-3 gap-y-1 border-l-4 py-2 pr-4",
      if(@level == 0, do: "bg-base-200/40 pl-3", else: "pl-8"),
      if(@group.problems, do: "border-error", else: "border-transparent")
    ]}>
      <button
        type="button"
        phx-click="toggle_group"
        phx-value-group={@group.id}
        aria-expanded={to_string(@open)}
        aria-controls={@dom_id <> "-body"}
        class="flex min-w-0 flex-1 items-center gap-2 text-left hover:underline"
      >
        <.icon
          name="hero-chevron-right-mini"
          class={["size-4 shrink-0 transition-transform", @open && "rotate-90"]}
        />
        <span class="truncate font-mono text-sm font-medium">
          <.group_name group={@group} />
        </span>
      </button>
      <.status_badge status={@group.worst} data-role="worst" />
      <span class="text-sm tabular-nums" data-role="up">
        {@group.counts.up}/{@group.total} up
      </span>
      <span
        :for={status <- @others}
        class={["text-xs font-medium tabular-nums", status_text_class(status)]}
        data-role={status}
      >
        {@group.counts[status]} {String.downcase(status_label(status))}
      </span>
      <span
        class={[
          "badge badge-sm w-16 justify-center font-semibold tabular-nums",
          uptime_class(@group.uptime)
        ]}
        title="Uptime (24h)"
        data-role="uptime"
      >
        {format_uptime(@group.uptime)}
      </span>
    </div>
    """
  end

  attr :group, Grouping.Group, required: true

  defp group_name(%{group: %{value: nil}} = assigns) do
    ~H"""
    <span class="opacity-60">{@group.key}:</span> <span class="italic">(none)</span>
    """
  end

  defp group_name(%{group: %{value: ""}} = assigns), do: ~H"{@group.key}"

  defp group_name(assigns) do
    ~H"""
    <span class="opacity-60">{@group.key}=</span>{@group.value}
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    monitors = Monitoring.list_monitors()

    if connected?(socket) do
      Monitoring.subscribe_monitors()
      Enum.each(monitors, &Monitoring.subscribe_monitor/1)
      Maintenance.subscribe()
    end

    ids = Enum.map(monitors, & &1.id)
    latest = Monitoring.latest_result_per_monitor()
    maintenance = Maintenance.active_windows_for(ids)
    checks = Stats.summaries(ids, @uptime_window)

    index =
      Map.new(monitors, fn monitor ->
        entry =
          index_entry(
            monitor,
            Map.get(latest, monitor.id),
            Map.get(maintenance, monitor.id, []),
            checks |> Map.get(monitor.id) |> check_counts()
          )

        {monitor.id, entry}
      end)

    socket =
      socket
      |> assign(page_title: "Dashboard", statuses: @statuses, index: index, layouts: @layouts)
      |> assign(view: %View{}, selector_text: "", selector_error: nil, suggestions: [])
      |> assign(overrides: restore_overrides(socket), groups: [], columns: [])
      |> assign_summary()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case View.from_params(params) do
        {:ok, view} ->
          # Keep the text as typed while it means the same.
          text =
            if Selector.parse(socket.assigns.selector_text) == {:ok, view.selector},
              do: socket.assigns.selector_text,
              else: Selector.to_string(view.selector)

          assign(socket, view: view, selector_text: text, selector_error: nil)

        {:error, view, text, error} ->
          assign(socket, view: view, selector_text: text, selector_error: error)
      end

    {:noreply, socket |> assign_suggestions() |> assign_groups()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    socket = assign(socket, selector_text: Map.get(params, "selector", ""))

    case View.from_params(Map.take(params, ~w(selector group sort layout))) do
      {:ok, view} ->
        {:noreply, socket |> assign_suggestions() |> push_patch(to: view_path(view))}

      # Shown inline; the list keeps showing the last valid selector's
      # monitors (regrouped when the grouping changed).
      {:error, view, _text, error} ->
        socket = socket |> assign(selector_error: error) |> assign_suggestions()
        current = %{view | selector: socket.assigns.view.selector}

        if current == socket.assigns.view,
          do: {:noreply, socket},
          else: {:noreply, push_patch(socket, to: view_path(current))}
    end
  end

  def handle_event("toggle_group", %{"group" => id}, socket) do
    case Enum.find(Grouping.flatten(socket.assigns.groups), &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      group ->
        expanded = not expanded?(socket.assigns.overrides, group)
        {:noreply, put_overrides(socket, [group], expanded)}
    end
  end

  def handle_event(event, _params, socket) when event in ["expand_all", "collapse_all"] do
    groups = Grouping.flatten(socket.assigns.groups)
    {:noreply, put_overrides(socket, groups, event == "expand_all")}
  end

  @impl true
  def handle_info({:monitor_created, monitor}, socket) do
    Monitoring.subscribe_monitor(monitor)

    maintenance = Maintenance.active_windows_for([monitor.id])
    entry = index_entry(monitor, nil, Map.get(maintenance, monitor.id, []), nil)
    {:noreply, put_index(socket, monitor.id, entry)}
  end

  def handle_info({:monitor_updated, monitor}, socket) do
    {:noreply,
     update_entry(socket, monitor.id, fn entry ->
       %{entry | monitor: monitor, status: display_status(monitor, entry.latest)}
     end)}
  end

  def handle_info({:monitor_deleted, monitor}, socket) do
    Monitoring.unsubscribe_monitor(monitor)

    socket =
      socket
      |> assign(index: Map.delete(socket.assigns.index, monitor.id))
      |> assign_summary()
      |> assign_groups()

    {:noreply, socket}
  end

  def handle_info({:check_result, result}, socket) do
    {:noreply,
     update_entry(socket, result.monitor_id, fn entry ->
       checks = Stats.summaries([result.monitor_id], @uptime_window)[result.monitor_id]

       %{
         entry
         | latest: result,
           status: display_status(entry.monitor, result),
           checks: check_counts(checks)
       }
     end)}
  end

  def handle_info({event, monitor, _result}, socket)
      when event in [:warning_raised, :warning_cleared] do
    {:noreply, update_entry(socket, monitor.id, &%{&1 | warning: event == :warning_raised})}
  end

  def handle_info({:maintenance_changed}, socket) do
    maintenance = Maintenance.active_windows_for(Map.keys(socket.assigns.index))

    index =
      Map.new(socket.assigns.index, fn {id, entry} ->
        {id, %{entry | maintenance: Map.get(maintenance, id, [])}}
      end)

    {:noreply, socket |> assign(index: index) |> assign_groups()}
  end

  # Status changes are covered by the check result that caused them.
  def handle_info(_message, socket), do: {:noreply, socket}

  ## Paths

  @doc """
  The dashboard path of a view (see `Sentinelix.Monitoring.View.to_params/1`).
  """
  @spec view_path(View.t()) :: String.t()
  def view_path(%View{} = view) do
    case View.to_params(view) do
      [] -> ~p"/"
      params -> ~p"/?#{params}"
    end
  end

  @doc "The dashboard path of a view with a selector term added."
  @spec add_term_path(View.t(), Selector.Term.t()) :: String.t()
  def add_term_path(%View{} = view, term),
    do: view_path(%{view | selector: Selector.add(view.selector || %Selector{}, term)})

  ## Index

  defp index_entry(monitor, latest, maintenance, checks) do
    %{
      monitor: monitor,
      latest: latest,
      status: display_status(monitor, latest),
      warning: warning?(monitor),
      maintenance: maintenance,
      checks: checks
    }
  end

  defp check_counts(nil), do: nil
  defp check_counts(summary), do: Map.take(summary, [:up, :down, :unreachable])

  defp warning?(%{enabled: false}), do: false

  defp warning?(monitor) do
    case Monitoring.worker_info(monitor) do
      %{warning: warning} -> warning
      nil -> false
    end
  end

  defp update_entry(socket, id, fun) do
    case Map.fetch(socket.assigns.index, id) do
      {:ok, entry} -> put_index(socket, id, fun.(entry))
      :error -> socket
    end
  end

  defp put_index(socket, id, entry) do
    socket
    |> assign(index: Map.put(socket.assigns.index, id, entry))
    |> assign_summary()
    |> assign_groups()
  end

  defp assign_summary(socket) do
    entries = Map.values(socket.assigns.index)
    counts = Map.merge(Map.new(@statuses, &{&1, 0}), Enum.frequencies_by(entries, & &1.status))
    assign(socket, counts: counts, total: length(entries))
  end

  # The groups of the monitors the selector shows (one group of all of
  # them without grouping); the Rows components stream what changed. In a
  # matrix the groups are its rows, with its columns. An invalid selector
  # (only from a hand-edited URL) shows no monitors.
  defp assign_groups(socket) do
    %{view: view, index: index} = socket.assigns

    entries =
      if view.selector,
        do: index |> Map.values() |> Enum.filter(&visible?(view.selector, &1)),
        else: []

    if View.matrix?(view) do
      %{rows: rows, columns: columns} =
        Grouping.matrix(entries, view.group_by, sort: view.sort)

      assign(socket, groups: rows, columns: columns)
    else
      assign(socket, groups: Grouping.group(entries, view.group_by, sort: view.sort), columns: [])
    end
  end

  defp visible?(selector, entry),
    do: Selector.matches?(selector, entry.monitor, status: entry.status)

  # Completions of the selector being typed and the keys to group by, from
  # the labels of the monitors in the index (user and automatic).
  defp assign_suggestions(socket) do
    label_values =
      socket.assigns.index
      |> Map.values()
      |> Enum.map(& &1.monitor)
      |> label_values()

    keys =
      label_values
      |> Map.keys()
      |> Kernel.++(socket.assigns.view.group_by)
      |> Enum.reject(&(&1 in Selector.pseudo_keys()))
      |> Enum.uniq()
      |> Enum.sort()

    assign(socket,
      suggestions: suggestions(socket.assigns.selector_text, completion_values(label_values)),
      group_keys: keys
    )
  end

  ## Expanded groups

  # `overrides` maps group ids to `{expanded, problems}`: expanded or
  # collapsed by the user while the group had problems or not. It applies
  # while the group's problem state is the same; otherwise groups with
  # problems are expanded.
  defp expanded?(_overrides, %Grouping.Group{key: nil}), do: true

  defp expanded?(overrides, %Grouping.Group{id: id, problems: problems}) do
    case Map.fetch(overrides, id) do
      {:ok, {expanded, ^problems}} -> expanded
      _default -> problems
    end
  end

  defp put_overrides(socket, groups, expanded) do
    overrides =
      groups
      |> Enum.reduce(socket.assigns.overrides, fn group, overrides ->
        if expanded == group.problems,
          do: Map.delete(overrides, group.id),
          else: Map.put(overrides, group.id, {expanded, group.problems})
      end)
      |> limit_overrides(socket.assigns.groups)

    socket
    |> assign(overrides: overrides)
    |> push_event("dashboard:groups", %{groups: encode_overrides(overrides)})
  end

  # Past the limit, the overrides of groups not shown are dropped.
  defp limit_overrides(overrides, _groups) when map_size(overrides) <= @max_overrides,
    do: overrides

  defp limit_overrides(overrides, groups) do
    overrides
    |> Map.take(groups |> Grouping.flatten() |> Enum.map(& &1.id))
    |> Enum.take(@max_overrides)
    |> Map.new()
  end

  defp encode_overrides(overrides) do
    Map.new(overrides, fn {id, {expanded, problems}} ->
      {id, %{"open" => expanded, "problems" => problems}}
    end)
  end

  # From the `dashboard_groups` connect parameter (as `encode_overrides/1`
  # writes it), which comes from the browser: anything unexpected is
  # ignored.
  defp restore_overrides(socket) do
    case connected?(socket) && get_connect_params(socket) do
      %{"dashboard_groups" => groups} when is_map(groups) ->
        groups
        |> Enum.flat_map(&restore_override/1)
        |> Enum.take(@max_overrides)
        |> Map.new()

      _none ->
        %{}
    end
  end

  defp restore_override({id, %{"open" => open, "problems" => problems}})
       when is_binary(id) and byte_size(id) <= 1024 and is_boolean(open) and
              is_boolean(problems),
       do: [{id, {open, problems}}]

  defp restore_override(_other), do: []

  ## Filtering

  defp status_selected?(nil, _status), do: false

  defp status_selected?(selector, status),
    do: Selector.member?(selector, Selector.status_term(status))

  # A status counter selects that status, or unselects it again.
  defp toggle_status(selector, status) do
    selector = selector || %Selector{}

    if status_selected?(selector, status),
      do: Selector.delete(selector, Selector.status_term(status)),
      else:
        selector |> Selector.delete_key("status") |> Selector.add(Selector.status_term(status))
  end

  defp group_dom_id(%Grouping.Group{id: id}),
    do: "group-" <> Base.url_encode64(id, padding: false)

  defp count_class(:down, %{down: n}) when n > 0, do: "text-error"
  defp count_class(_status, _counts), do: nil
end
