defmodule SentinelixWeb.DashboardLive do
  @moduledoc """
  The dashboard: status counters and all monitors with their current
  status, a heartbeat bar of the latest checks, the 24h uptime and the
  latest response time. Updates in real time.

  The monitor rows are a stream; the LiveView only keeps a small index
  (monitor + status per id) for the counters and filtering. A check result
  re-renders just the affected row.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents

  alias Sentinelix.{Maintenance, Monitoring}
  alias Sentinelix.Monitoring.{History, Labels}
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
          patch={filter_path(@filters, status: toggle(@filters.status, status))}
          class={[
            "rounded-box border bg-base-100 p-4 transition hover:border-base-content/30",
            @filters.status == status && "border-base-content/40 ring-1 ring-base-content/20",
            @filters.status != status && "border-base-300"
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
        <.form
          for={@filter_form}
          id="filter-form"
          phx-change="filter"
          phx-submit="filter"
          class="flex flex-col gap-2 border-b border-base-300 p-3 sm:flex-row sm:items-center"
        >
          <label class="input input-sm w-full sm:max-w-xs">
            <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
            <input
              type="search"
              name="q"
              value={@filters.q}
              placeholder="Search monitors"
              phx-debounce="200"
              autocomplete="off"
            />
          </label>
          <select name="status" class="select select-sm w-full sm:w-40" aria-label="Status">
            {Phoenix.HTML.Form.options_for_select(
              [{"All statuses", ""} | Enum.map(@statuses, &{status_label(&1), &1})],
              @filters.status
            )}
          </select>
          <select
            :if={@labels != []}
            name="label"
            class="select select-sm w-full font-mono sm:w-48"
            aria-label="Label"
          >
            {Phoenix.HTML.Form.options_for_select([{"All labels", ""} | @labels], @filters.label)}
          </select>
          <.link
            :if={@filters != %{q: "", status: nil, label: nil}}
            patch={~p"/"}
            class="btn btn-ghost btn-sm"
            id="clear-filters"
          >
            Clear
          </.link>
        </.form>

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
                    patch={&filter_path(@filters, label: Labels.format(&1))}
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
      |> assign(filters: %{q: "", status: nil, label: nil})
      |> stream_configure(:monitors, dom_id: &"monitor-#{&1.id}")
      |> assign_summary()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      q: params |> Map.get("q", "") |> String.trim(),
      status: parse_status(params["status"]),
      # `tag` is the parameter of the tag filter that labels replaced.
      label: parse_label(params["label"] || params["tag"])
    }

    socket =
      socket
      |> assign(filters: filters, filter_form: to_form(params))
      |> stream_rows(reset: true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters = %{
      q: String.trim(params["q"] || ""),
      status: parse_status(params["status"]),
      label: parse_label(params["label"])
    }

    {:noreply, push_patch(socket, to: filter_path(filters, []))}
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

    # The label filter's options: user labels, then automatic ones.
    labels =
      case {label_options(entries, :labels), label_options(entries, :auto_labels)} do
        {[], []} -> []
        {user, automatic} -> user ++ [{"Automatic", automatic}]
      end

    assign(socket, counts: counts, labels: labels, total: length(entries))
  end

  defp label_options(entries, field) do
    entries
    |> Enum.flat_map(&Labels.to_list(Map.fetch!(&1.monitor, field)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Labels.format/1)
  end

  defp visible_entries(socket) do
    filters = socket.assigns.filters
    label = filters.label && elem(Labels.parse(filters.label), 1)

    socket.assigns.index
    |> Map.values()
    |> Enum.filter(&matches?(&1, filters, label))
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

  defp matches?(entry, filters, label) do
    (filters.status == nil or entry.status == filters.status) and
      (label == nil or Labels.has?(entry.monitor.all_labels, label)) and
      matches_search?(entry.monitor, filters.q)
  end

  # The label filter, normalized ("Env = prod" -> "env=prod"), or nil.
  defp parse_label(value) when is_binary(value) and value != "" do
    case Labels.parse(value) do
      {:ok, label} -> Labels.format(label)
      {:error, _message} -> nil
    end
  end

  defp parse_label(_value), do: nil

  defp parse_status(status) when is_binary(status) do
    Enum.find(@statuses, &(Atom.to_string(&1) == status))
  end

  defp parse_status(_status), do: nil

  defp toggle(current, status) when current == status, do: nil
  defp toggle(_current, status), do: status

  defp filter_path(filters, overrides) do
    query =
      filters
      |> Map.merge(Map.new(overrides))
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    ~p"/?#{query}"
  end

  defp heartbeats, do: @heartbeats

  defp count_class(:down, %{down: n}) when n > 0, do: "text-error"
  defp count_class(_status, _counts), do: nil

  defp uptime_class(%{uptime: nil}), do: "badge-ghost"
  defp uptime_class(%{uptime: uptime}) when uptime >= 99, do: "badge-success"
  defp uptime_class(%{uptime: uptime}) when uptime >= 95, do: "badge-warning"
  defp uptime_class(_row), do: "badge-error"
end
