defmodule SentinelixWeb.DashboardLive do
  @moduledoc """
  The dashboard: status counters and all monitors with their current
  status, a heartbeat bar of the latest checks, the 24h uptime and the
  latest response time. Updates in real time.

  The monitor rows are a stream; the LiveView only keeps a small index
  (monitor + status per id) for the counters and filtering. A check result
  re-renders just the affected row.

  ## Filtering

  The monitors are filtered by a selector (`Sentinelix.Monitoring.Selector`)
  kept in the URL (`?selector=env=prod,status=down`) and evaluated on the
  index, with the status shown, so rows come and go as statuses change.
  The status counters toggle a `status=` term, label badges add a term.
  Links from before selectors keep working: `?q=` becomes `name~`, and
  `?status=`, `?label=` and `?tag=` become terms too.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents
  import SentinelixWeb.SelectorComponents

  alias Sentinelix.{Maintenance, Monitoring}
  alias Sentinelix.Monitoring.{History, Labels, Selector}
  alias Sentinelix.Stats

  @heartbeats 50
  @uptime_window {24, :hour}
  @statuses ~w(up down pending maintenance paused)a

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

      <div id="status-counters" class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
        <.link
          :for={status <- @statuses}
          id={"counter-#{status}"}
          patch={filter_path(toggle_status(@selector, status))}
          class={[
            "rounded-box border bg-base-100 p-4 transition hover:border-base-content/30",
            if(status_selected?(@selector, status),
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
          class="flex items-start gap-2 border-b border-base-300 p-3"
        >
          <.selector_input
            id="selector"
            value={@selector_text}
            error={@selector_error}
            suggestions={@suggestions}
            class="sm:max-w-xl"
          />
          <.link
            :if={@selector_text != ""}
            patch={~p"/"}
            class="btn btn-ghost btn-sm"
            id="clear-filters"
          >
            Clear
          </.link>
        </form>

        <div id="monitors" phx-update="stream" class="divide-y divide-base-300">
          <div
            id="monitors-empty"
            class="hidden px-6 py-10 text-center text-sm text-base-content/60 only:block"
          >
            No monitors match your filters.
          </div>
          <div
            :for={{dom_id, row} <- @streams.monitors}
            id={dom_id}
            class="flex flex-col gap-3 px-4 py-3 transition hover:bg-base-200/50 md:flex-row md:items-center"
          >
            <div class="flex min-w-0 flex-1 items-center gap-3">
              <span
                class={[
                  "badge badge-sm w-16 shrink-0 justify-center font-semibold tabular-nums",
                  uptime_class(row)
                ]}
                title="Uptime (24h)"
              >
                {format_uptime(row.uptime)}
              </span>
              <div class="min-w-0">
                <.link
                  navigate={~p"/monitors/#{row.monitor.id}"}
                  class="block truncate font-medium hover:underline"
                >
                  {row.monitor.name}
                </.link>
                <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/60">
                  <span>{type_label(row.monitor.type)}</span>
                  <span :if={target(row.monitor)} class="max-w-xs truncate">
                    · {target(row.monitor)}
                  </span>
                  <.label_badges
                    labels={row.monitor.labels}
                    patch={
                      &filter_path(Selector.add(@selector || %Selector{}, Selector.label_term(&1)))
                    }
                  />
                  <span
                    :if={row.warning}
                    class="badge badge-warning badge-xs gap-1"
                    title={row.latest && row.latest.message}
                  >
                    <.icon name="hero-exclamation-triangle-micro" class="size-3" /> Warning
                  </span>
                  <.maintenance_badge id={"maintenance-#{row.id}"} windows={row.maintenance} />
                </div>
              </div>
            </div>
            <div class="flex items-center gap-3 md:w-[30rem]">
              <.heartbeat_bar
                id={"heartbeats-#{row.id}"}
                results={row.results}
                slots={heartbeats()}
                class="min-w-0 flex-1"
              />
              <div class="flex w-24 shrink-0 flex-col items-end gap-1">
                <.status_badge status={row.status} />
                <span class="text-xs tabular-nums text-base-content/60">
                  {format_ms(row.latest && row.latest.response_time_ms)}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
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

    latest = Monitoring.latest_result_per_monitor()
    maintenance = Maintenance.active_windows_for(Enum.map(monitors, & &1.id))

    index =
      Map.new(monitors, fn monitor ->
        entry =
          index_entry(monitor, Map.get(latest, monitor.id), Map.get(maintenance, monitor.id, []))

        {monitor.id, entry}
      end)

    socket =
      socket
      |> assign(page_title: "Dashboard", statuses: @statuses, index: index)
      |> assign(selector: %Selector{}, selector_text: "", selector_error: nil, suggestions: [])
      |> stream_configure(:monitors, dom_id: &"monitor-#{&1.id}")
      |> assign_summary()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params_selector(params) do
        {:ok, selector} ->
          # Keep the text as typed while it means the same.
          text =
            if Selector.parse(socket.assigns.selector_text) == {:ok, selector},
              do: socket.assigns.selector_text,
              else: Selector.to_string(selector)

          assign(socket, selector: selector, selector_text: text, selector_error: nil)

        {:error, text, error} ->
          assign(socket, selector: nil, selector_text: text, selector_error: error)
      end

    {:noreply, socket |> assign_suggestions() |> stream_rows(reset: true)}
  end

  @impl true
  def handle_event("filter", %{"selector" => text}, socket) do
    socket = assign(socket, selector_text: text)

    case Selector.parse(text) do
      {:ok, selector} ->
        {:noreply, socket |> assign_suggestions() |> push_patch(to: filter_path(selector))}

      # Shown inline; the list keeps showing the last valid selector's monitors.
      {:error, error} ->
        {:noreply, socket |> assign(selector_error: error) |> assign_suggestions()}
    end
  end

  @impl true
  def handle_info({:monitor_created, monitor}, socket) do
    Monitoring.subscribe_monitor(monitor)

    maintenance = Maintenance.active_windows_for([monitor.id])
    entry = index_entry(monitor, nil, Map.get(maintenance, monitor.id, []))
    {:noreply, socket |> put_index(monitor.id, entry) |> refresh_row(monitor.id)}
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
      |> stream_delete_by_dom_id(:monitors, "monitor-#{monitor.id}")

    {:noreply, socket}
  end

  def handle_info({:check_result, result}, socket) do
    {:noreply,
     update_entry(socket, result.monitor_id, fn entry ->
       %{entry | latest: result, status: display_status(entry.monitor, result)}
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

    {:noreply, socket |> assign(index: index) |> stream_rows(reset: true)}
  end

  # Status changes are covered by the check result that caused them.
  def handle_info(_message, socket), do: {:noreply, socket}

  ## Index and rows

  defp index_entry(monitor, latest, maintenance) do
    %{
      monitor: monitor,
      latest: latest,
      status: display_status(monitor, latest),
      warning: warning?(monitor),
      maintenance: maintenance
    }
  end

  defp warning?(%{enabled: false}), do: false

  defp warning?(monitor) do
    case Monitoring.worker_info(monitor) do
      %{warning: warning} -> warning
      nil -> false
    end
  end

  defp update_entry(socket, id, fun) do
    case Map.fetch(socket.assigns.index, id) do
      {:ok, entry} -> socket |> put_index(id, fun.(entry)) |> refresh_row(id)
      :error -> socket
    end
  end

  defp put_index(socket, id, entry) do
    socket
    |> assign(index: Map.put(socket.assigns.index, id, entry))
    |> assign_summary()
  end

  defp assign_summary(socket) do
    entries = Map.values(socket.assigns.index)
    counts = Map.merge(Map.new(@statuses, &{&1, 0}), Enum.frequencies_by(entries, & &1.status))
    assign(socket, counts: counts, total: length(entries))
  end

  # Completions of the selector being typed, from the labels of the
  # monitors in the index (user and automatic).
  defp assign_suggestions(socket) do
    values =
      socket.assigns.index
      |> Map.values()
      |> Enum.map(& &1.monitor)
      |> label_values()
      |> completion_values()

    assign(socket, suggestions: suggestions(socket.assigns.selector_text, values))
  end

  # An invalid selector (only from a hand-edited URL) shows no monitors.
  defp visible_entries(%{assigns: %{selector: nil}}), do: []

  defp visible_entries(socket) do
    selector = socket.assigns.selector

    socket.assigns.index
    |> Map.values()
    |> Enum.filter(&Selector.matches?(selector, &1.monitor, status: &1.status))
    |> Enum.sort_by(&{String.downcase(&1.monitor.name), &1.monitor.id})
  end

  defp stream_rows(socket, opts) do
    entries = visible_entries(socket)
    ids = Enum.map(entries, & &1.monitor.id)
    results = History.recent_results_by_monitor(@heartbeats, ids)
    uptime = Stats.uptimes(ids, @uptime_window)

    rows =
      Enum.map(entries, fn entry ->
        build_row(
          entry,
          Map.get(results, entry.monitor.id, []),
          Map.get(uptime, entry.monitor.id)
        )
      end)

    stream(socket, :monitors, rows, opts)
  end

  defp refresh_row(socket, id) do
    entries = visible_entries(socket)

    case Enum.find_index(entries, &(&1.monitor.id == id)) do
      nil ->
        stream_delete_by_dom_id(socket, :monitors, "monitor-#{id}")

      position ->
        results = History.recent_results_by_monitor(@heartbeats, [id])

        row =
          build_row(
            Enum.at(entries, position),
            Map.get(results, id, []),
            Stats.uptime(id, @uptime_window)
          )

        stream_insert(socket, :monitors, row, at: position)
    end
  end

  defp build_row(entry, results, uptime) do
    Map.merge(entry, %{id: entry.monitor.id, results: results, uptime: uptime})
  end

  ## Filtering

  # The selector of the URL (`?selector=`), plus the filters of older links
  # translated to terms: `?q=` (search, now `name~`), `?status=`,
  # `?label=` and `?tag=` (the filter that labels replaced).
  defp params_selector(params) do
    text = params["selector"] || ""

    case Selector.parse(text) do
      {:ok, selector} -> {:ok, Enum.reduce(legacy_terms(params), selector, &Selector.add(&2, &1))}
      {:error, error} -> {:error, text, error}
    end
  end

  defp legacy_terms(params) do
    search =
      case String.trim(params["q"] || "") do
        "" -> []
        text -> [Selector.name_term(text)]
      end

    status =
      case Enum.find(@statuses, &(Atom.to_string(&1) == params["status"])) do
        nil -> []
        status -> [Selector.status_term(status)]
      end

    label =
      case Labels.parse(params["label"] || params["tag"] || "") do
        {:ok, label} -> [Selector.label_term(label)]
        {:error, _message} -> []
      end

    search ++ status ++ label
  end

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

  defp filter_path(selector) do
    if Selector.empty?(selector),
      do: ~p"/",
      else: ~p"/?#{[selector: Selector.to_string(selector)]}"
  end

  defp heartbeats, do: @heartbeats

  defp count_class(:down, %{down: n}) when n > 0, do: "text-error"
  defp count_class(_status, _counts), do: nil

  defp uptime_class(%{uptime: nil}), do: "badge-ghost"
  defp uptime_class(%{uptime: uptime}) when uptime >= 99, do: "badge-success"
  defp uptime_class(%{uptime: uptime}) when uptime >= 95, do: "badge-warning"
  defp uptime_class(_row), do: "badge-error"
end
