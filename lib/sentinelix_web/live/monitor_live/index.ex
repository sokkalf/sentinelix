defmodule SentinelixWeb.MonitorLive.Index do
  @moduledoc """
  Monitor management: all monitors in a table with their configuration and
  actions (pause/resume, edit, clone, delete).
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents

  alias Sentinelix.{Maintenance, Monitoring}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:monitors}>
      <.header>
        Monitors
        <:subtitle>{@count} {if @count == 1, do: "monitor", else: "monitors"} configured</:subtitle>
        <:actions>
          <.button navigate={~p"/monitors/new"} variant="primary" id="new-monitor">
            <.icon name="hero-plus" class="size-4" /> Add monitor
          </.button>
        </:actions>
      </.header>

      <div class="rounded-box border border-base-300 bg-base-100">
        <form
          id="search-form"
          phx-change="search"
          phx-submit="search"
          class="border-b border-base-300 p-3"
        >
          <label class="input input-sm w-full sm:max-w-xs">
            <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
            <input
              type="search"
              name="q"
              value={@q}
              placeholder="Search by name, target or label"
              phx-debounce="200"
              autocomplete="off"
            />
          </label>
        </form>

        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Name</th>
                <th class="hidden md:table-cell">Type</th>
                <th class="hidden lg:table-cell">Target</th>
                <th class="hidden sm:table-cell">Interval</th>
                <th>Status</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody id="monitors" phx-update="stream">
              <tr id="monitors-empty" class="hidden only:table-row">
                <td colspan="6" class="py-10 text-center text-base-content/60">
                  {if @count == 0, do: "No monitors yet.", else: "No monitors match your search."}
                </td>
              </tr>
              <tr :for={{dom_id, row} <- @streams.monitors} id={dom_id} class="hover:bg-base-200/50">
                <td class="max-w-56">
                  <.link
                    navigate={~p"/monitors/#{row.monitor.id}"}
                    class="block truncate font-medium hover:underline"
                  >
                    {row.monitor.name}
                  </.link>
                  <div
                    :if={row.monitor.labels != %{} or row.maintenance != []}
                    class="mt-1 flex flex-wrap gap-1"
                  >
                    <.maintenance_badge id={"maintenance-#{row.id}"} windows={row.maintenance} />
                    <.label_badges labels={row.monitor.labels} />
                  </div>
                </td>
                <td class="hidden whitespace-nowrap md:table-cell">{type_label(row.monitor.type)}</td>
                <td class="hidden max-w-xs truncate text-base-content/70 lg:table-cell">
                  {target(row.monitor) || "–"}
                </td>
                <td class="hidden whitespace-nowrap tabular-nums sm:table-cell">
                  {format_duration(row.monitor.interval_seconds)}
                </td>
                <td><.status_badge status={row.status} /></td>
                <td>
                  <div class="flex justify-end gap-1">
                    <button
                      type="button"
                      phx-click="toggle"
                      phx-value-id={row.monitor.id}
                      class="btn btn-ghost btn-xs"
                      title={if row.monitor.enabled, do: "Pause", else: "Resume"}
                      id={"toggle-#{row.monitor.id}"}
                    >
                      <.icon :if={row.monitor.enabled} name="hero-pause" class="size-4" />
                      <.icon :if={!row.monitor.enabled} name="hero-play" class="size-4" />
                    </button>
                    <.link
                      navigate={~p"/monitors/#{row.monitor.id}/edit"}
                      class="btn btn-ghost btn-xs"
                      title="Edit"
                    >
                      <.icon name="hero-pencil-square" class="size-4" />
                    </.link>
                    <.link
                      navigate={~p"/monitors/#{row.monitor.id}/clone"}
                      class="btn btn-ghost btn-xs"
                      title="Clone"
                      id={"clone-#{row.monitor.id}"}
                    >
                      <.icon name="hero-document-duplicate" class="size-4" />
                    </.link>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-id={row.monitor.id}
                      data-confirm={"Delete #{row.monitor.name} and all of its history?"}
                      class="btn btn-ghost btn-xs text-error"
                      title="Delete"
                      id={"delete-#{row.monitor.id}"}
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Monitoring.subscribe_monitors()
      Monitoring.subscribe_status_changes()
      Maintenance.subscribe()
    end

    socket =
      socket
      |> assign(page_title: "Monitors", q: "")
      |> stream_configure(:monitors, dom_id: &"monitor-#{&1.id}")
      |> load()

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(q: String.trim(q)) |> load()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with %{} = monitor <- get_monitor(id),
         {:ok, monitor} <- Monitoring.toggle_monitor(monitor) do
      verb = if monitor.enabled, do: "resumed", else: "paused"
      {:noreply, put_flash(socket, :info, "#{monitor.name} #{verb}.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update the monitor.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %{} = monitor <- get_monitor(id),
         {:ok, monitor} <- Monitoring.delete_monitor(monitor) do
      {:noreply, put_flash(socket, :info, "#{monitor.name} deleted.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete the monitor.")}
    end
  end

  @impl true
  def handle_info({:monitor_created, monitor}, socket) do
    {:noreply, socket |> update(:count, &(&1 + 1)) |> upsert(monitor, current_status(monitor))}
  end

  def handle_info({:monitor_updated, monitor}, socket) do
    {:noreply, upsert(socket, monitor, current_status(monitor))}
  end

  def handle_info({:monitor_deleted, monitor}, socket) do
    {:noreply,
     socket
     |> update(:count, &max(&1 - 1, 0))
     |> stream_delete_by_dom_id(:monitors, "monitor-#{monitor.id}")}
  end

  def handle_info({:status_changed, %{id: id}, _old, _new, result}, socket) do
    case Monitoring.get_monitor(id) do
      nil -> {:noreply, socket}
      monitor -> {:noreply, upsert(socket, monitor, display_status(monitor, result))}
    end
  end

  def handle_info({:maintenance_changed}, socket), do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    latest = Monitoring.latest_result_per_monitor()
    monitors = Monitoring.list_monitors()
    maintenance = Maintenance.active_windows_for(Enum.map(monitors, & &1.id))

    rows =
      monitors
      |> Enum.filter(&matches_search?(&1, socket.assigns.q))
      |> Enum.map(&row(&1, display_status(&1, latest[&1.id]), Map.get(maintenance, &1.id, [])))

    socket
    |> assign(count: length(monitors))
    |> stream(:monitors, rows, reset: true)
  end

  defp upsert(socket, monitor, status) do
    if matches_search?(monitor, socket.assigns.q) do
      stream_insert(socket, :monitors, row(monitor, status))
    else
      stream_delete_by_dom_id(socket, :monitors, "monitor-#{monitor.id}")
    end
  end

  defp row(monitor, status, maintenance \\ nil) do
    maintenance =
      maintenance || Map.get(Maintenance.active_windows_for([monitor.id]), monitor.id, [])

    %{id: monitor.id, monitor: monitor, status: status, maintenance: maintenance}
  end

  defp current_status(monitor),
    do: display_status(monitor, Monitoring.get_latest_result(monitor))

  defp get_monitor(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Monitoring.get_monitor(id)
      _ -> nil
    end
  end
end
