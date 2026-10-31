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

  ## Saved views

  A view can be saved under a name (`Sentinelix.SavedViews`) and is then
  shown at `/views/<slug>`. Changing it there keeps the slug in the path
  (`/views/<slug>?group=site`): the URL parameters replace the stored view,
  so its owner can "Update view" with them, and "Reset" goes back to it.
  A changed view that is all defaults is `?selector=` (an empty selector),
  since no parameters means the stored view.

  At `/` without parameters a user who picked a default view sees it (the
  URL is patched to `/views/<slug>`). The unfiltered dashboard is then
  `/?selector=`, which "Show all monitors" links to.

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
  import SentinelixWeb.SavedViewComponents

  alias Sentinelix.{Maintenance, Monitoring, SavedViews, Stats}
  alias Sentinelix.Monitoring.{Grouping, Selector, View}
  alias Sentinelix.SavedViews.SavedView
  alias SentinelixWeb.DashboardLive.{Matrix, Rows}

  @uptime_window {24, :hour}
  @statuses ~w(up down pending unreachable maintenance paused)a
  @max_overrides 500
  @layouts [list: "List", grid: "Grid", matrix: "Matrix"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={if @saved_view, do: {:view, @saved_view.slug}, else: :dashboard}
    >
      <.header>
        {if @saved_view, do: @saved_view.name, else: "Dashboard"}
        <:subtitle>
          <%= if @saved_view do %>
            <span id="saved-view-info" class="inline-flex flex-wrap items-center gap-2">
              <.visibility_badge view={@saved_view} />
              <span>Saved view by {owner_name(@saved_view, @current_scope)}</span>
              <span :if={@modified} id="view-modified" class="badge badge-sm badge-warning">
                changed
              </span>
              <.link
                patch={view_path(%View{}, explicit: @default_view != nil)}
                id="show-all"
                class="link link-hover"
              >
                Show all monitors
              </.link>
            </span>
          <% else %>
            Live status of all monitors
          <% end %>
        </:subtitle>
        <:actions>
          <div class="flex flex-wrap items-center justify-end gap-2">
            <%= if @saved_view do %>
              <button
                type="button"
                id="toggle-default"
                phx-click="toggle_default"
                class="btn btn-ghost btn-sm"
                title={
                  if default?(@default_view, @saved_view),
                    do: "Your default view (shown at /). Click to unset.",
                    else: "Show this view at / (your default view)"
                }
              >
                <.icon
                  name={
                    if default?(@default_view, @saved_view), do: "hero-star-solid", else: "hero-star"
                  }
                  class="size-4"
                />
                {if default?(@default_view, @saved_view), do: "Default", else: "Make default"}
              </button>
              <.link
                :if={@modified}
                patch={~p"/views/#{@saved_view.slug}"}
                id="reset-view"
                class="btn btn-ghost btn-sm"
              >
                Reset
              </.link>
              <.button
                :if={@modified and SavedViews.owner?(@current_scope, @saved_view)}
                type="button"
                id="update-view"
                phx-click="update_view"
                disabled={not savable?(assigns)}
              >
                <.icon name="hero-check" class="size-4" /> Update view
              </.button>
              <.button
                :if={SavedViews.owner?(@current_scope, @saved_view)}
                navigate={~p"/views/#{@saved_view.slug}/edit"}
                id="edit-view"
              >
                <.icon name="hero-pencil-square" class="size-4" /> Edit
              </.button>
            <% end %>
            <.button
              type="button"
              id="save-view"
              phx-click="new_view"
              disabled={not savable?(assigns)}
              title={if savable?(assigns), do: nil, else: "Fix the selector to save this view"}
            >
              <.icon name="hero-bookmark" class="size-4" />
              {if @saved_view, do: "Save as new view", else: "Save view"}
            </.button>
            <.button navigate={~p"/monitors/new"} variant="primary" id="new-monitor">
              <.icon name="hero-plus" class="size-4" /> Add monitor
            </.button>
          </div>
        </:actions>
      </.header>

      <.form
        :if={@save_form}
        for={@save_form}
        id="save-view-form"
        phx-change="validate_view"
        phx-submit="save_view"
        class="rounded-box border border-base-300 bg-base-100 p-4"
      >
        <h2 class="mb-2 font-semibold">Save this view</h2>
        <div class="grid gap-x-6 sm:grid-cols-2">
          <div><.saved_view_fields form={@save_form} groups={@current_scope.groups} /></div>
          <div class="text-sm text-base-content/70">
            <p>
              Saves the filter, grouping, sort and layout shown below under a name. It's
              listed in the sidebar of everyone who can see it; only you can change it.
            </p>
            <.input
              type="checkbox"
              name="default"
              id="save-view-default"
              label="Make it my default view (shown at /)"
              value={false}
            />
          </div>
        </div>
        <div class="mt-2 flex gap-2">
          <.button variant="primary" phx-disable-with="Saving...">Save view</.button>
          <.button type="button" phx-click="cancel_save" id="cancel-save">Cancel</.button>
        </div>
      </.form>

      <div id="status-counters" class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
        <.link
          :for={status <- @statuses}
          id={"counter-#{status}"}
          patch={view_path(%{@view | selector: toggle_status(@view.selector, status)}, @path_opts)}
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
            patch={view_path(%{@view | selector: %Selector{}}, @path_opts)}
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
          path_opts={@path_opts}
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
            path_opts={@path_opts}
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
          path_opts={@path_opts}
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
  attr :path_opts, :list, required: true
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
            path_opts={@path_opts}
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
          path_opts={@path_opts}
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
      |> assign(saved_view: nil, modified: false, path_opts: [], save_form: nil)
      |> assign(default_view: SavedViews.default_view(socket.assigns.current_scope))
      |> assign(overrides: restore_overrides(socket), groups: [], columns: [])
      |> assign_summary()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :saved -> saved_view_params(params, socket)
      :index -> dashboard_params(params, socket)
    end
  end

  # `/` without parameters shows the default view, if any.
  defp dashboard_params(params, socket) when params == %{} do
    case socket.assigns.default_view do
      %SavedView{slug: slug} ->
        {:noreply, push_patch(socket, to: ~p"/views/#{slug}", replace: true)}

      nil ->
        apply_view(params, assign(socket, saved_view: nil, modified: false, path_opts: []))
    end
  end

  defp dashboard_params(params, socket) do
    socket =
      assign(socket,
        saved_view: nil,
        modified: false,
        path_opts: [explicit: socket.assigns.default_view != nil]
      )

    apply_view(params, socket)
  end

  # A saved view, changed by the URL parameters if there are any.
  defp saved_view_params(%{"slug" => slug} = params, socket) do
    case SavedViews.get_view(socket.assigns.current_scope, slug) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That view doesn't exist or isn't shared with you.")
         |> push_navigate(to: view_path(%View{}, explicit: true))}

      saved ->
        params = Map.delete(params, "slug")
        modified = params != %{}
        socket = assign(socket, saved_view: saved, modified: modified, path_opts: [saved: saved])
        apply_view(if(modified, do: params, else: saved.params), socket)
    end
  end

  defp apply_view(params, socket) do
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

    {:noreply, socket |> assign_modified() |> assign_suggestions() |> assign_groups()}
  end

  # A changed view that's the same as the stored one isn't changed.
  defp assign_modified(%{assigns: %{saved_view: %SavedView{} = saved}} = socket) do
    assign(socket,
      modified:
        socket.assigns.modified and
          (socket.assigns.selector_error != nil or
             not SavedViews.same_view?(saved, socket.assigns.view))
    )
  end

  defp assign_modified(socket), do: socket

  # Only a view with a valid selector can be saved.
  defp savable?(assigns), do: assigns.view.selector != nil and assigns.selector_error == nil

  defp default?(%SavedView{id: id}, %SavedView{id: id}), do: true
  defp default?(_default, _view), do: false

  @impl true
  def handle_event("filter", params, socket) do
    socket = assign(socket, selector_text: Map.get(params, "selector", ""))

    case View.from_params(Map.take(params, ~w(selector group sort layout))) do
      {:ok, view} ->
        {:noreply,
         socket
         |> assign_suggestions()
         |> push_patch(to: view_path(view, socket.assigns.path_opts))}

      # Shown inline; the list keeps showing the last valid selector's
      # monitors (regrouped when the grouping changed).
      {:error, view, _text, error} ->
        socket = socket |> assign(selector_error: error) |> assign_suggestions()
        current = %{view | selector: socket.assigns.view.selector}

        if current == socket.assigns.view,
          do: {:noreply, socket},
          else: {:noreply, push_patch(socket, to: view_path(current, socket.assigns.path_opts))}
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

  def handle_event("new_view", _params, socket) do
    form =
      socket.assigns.current_scope
      |> SavedViews.change_view(%SavedView{})
      |> to_form()

    {:noreply, assign(socket, save_form: form)}
  end

  def handle_event("cancel_save", _params, socket), do: {:noreply, assign(socket, save_form: nil)}

  def handle_event("validate_view", %{"saved_view" => attrs}, socket) do
    form =
      socket.assigns.current_scope
      |> SavedViews.change_view(%SavedView{}, attrs)
      |> to_form(action: :validate)

    {:noreply, assign(socket, save_form: form)}
  end

  def handle_event("save_view", %{"saved_view" => attrs} = params, socket) do
    scope = socket.assigns.current_scope

    with true <- savable?(socket.assigns) || {:error, :invalid_view},
         {:ok, saved} <- SavedViews.create_view(scope, socket.assigns.view, attrs) do
      socket =
        if params["default"] == "true", do: put_default_view(socket, saved), else: socket

      {:noreply,
       socket
       |> assign(save_form: nil)
       |> put_flash(:info, "View \"#{saved.name}\" saved.")
       |> push_patch(to: ~p"/views/#{saved.slug}")}
    else
      {:error, :invalid_view} ->
        {:noreply, put_flash(socket, :error, "Fix the selector to save this view.")}

      {:error, changeset} ->
        {:noreply, assign(socket, save_form: to_form(changeset))}
    end
  end

  def handle_event("update_view", _params, %{assigns: %{saved_view: %SavedView{}}} = socket) do
    %{current_scope: scope, saved_view: saved, view: view} = socket.assigns

    result =
      if savable?(socket.assigns),
        do: SavedViews.update_view_params(scope, saved, view),
        else: {:error, :invalid_view}

    case result do
      {:ok, saved} ->
        {:noreply,
         socket
         |> put_flash(:info, "View \"#{saved.name}\" updated.")
         |> push_patch(to: ~p"/views/#{saved.slug}")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only the owner of a view can change it.")}

      {:error, :invalid_view} ->
        {:noreply, put_flash(socket, :error, "Fix the selector to save this view.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "The view could not be updated.")}
    end
  end

  def handle_event("toggle_default", _params, %{assigns: %{saved_view: %SavedView{}}} = socket) do
    %{saved_view: saved, default_view: default} = socket.assigns

    if default?(default, saved),
      do: {:noreply, put_default_view(socket, nil)},
      else: {:noreply, put_default_view(socket, saved)}
  end

  def handle_event(event, _params, socket) when event in ["update_view", "toggle_default"],
    do: {:noreply, socket}

  defp put_default_view(socket, view) do
    scope = socket.assigns.current_scope

    case SavedViews.set_default_view(scope, view) do
      {:ok, user} ->
        assign(socket, current_scope: %{scope | user: user}, default_view: view)

      {:error, :not_found} ->
        put_flash(socket, :error, "That view isn't shared with you.")
    end
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

  ## Options

    * `:saved` – the `Sentinelix.SavedViews.SavedView` being changed: the
      path is that view's (`/views/<slug>`), with the parameters when the
      view differs from the stored one.
    * `:explicit` – when true, a view that is all defaults is
      `/?selector=` rather than `/` (which shows the user's default view).
  """
  @spec view_path(View.t(), keyword()) :: String.t()
  def view_path(%View{} = view, opts \\ []) do
    params = View.to_params(view)

    case Keyword.get(opts, :saved) do
      %SavedView{slug: slug} = saved ->
        if SavedViews.same_view?(saved, view),
          do: ~p"/views/#{slug}",
          else: ~p"/views/#{slug}?#{explicit_params(params)}"

      nil ->
        cond do
          params != [] -> ~p"/?#{params}"
          Keyword.get(opts, :explicit, false) -> ~p"/?#{explicit_params(params)}"
          true -> ~p"/"
        end
    end
  end

  defp explicit_params([]), do: [selector: ""]
  defp explicit_params(params), do: params

  @doc """
  The dashboard path of a view with a selector term added (options as for
  `view_path/2`).
  """
  @spec add_term_path(View.t(), Selector.Term.t(), keyword()) :: String.t()
  def add_term_path(%View{} = view, term, opts \\ []),
    do: view_path(%{view | selector: Selector.add(view.selector || %Selector{}, term)}, opts)

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
