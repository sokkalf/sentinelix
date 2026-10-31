defmodule SentinelixWeb.DashboardLive.Rows do
  @moduledoc """
  The monitors of one dashboard group (or of all of them when not
  grouping), as a stream: rows in the list layout, tiles
  (`SentinelixWeb.MonitorComponents.monitor_tile/1`) in the grid layout
  (see `Sentinelix.Monitoring.View`). Each is `monitor-<id>`.

  The dashboard passes the group's `entries` (from its index, sorted) on
  every change; the component compares them with what it rendered and
  only streams the rows that changed, were added or were removed. A check
  result therefore re-renders one row, and a group that isn't expanded
  isn't rendered at all (no component, no rows, no queries). The heartbeats
  of the rows to render are loaded in one query for all groups updated
  together (`update_many/1`); tiles have no heartbeats and need no query.

  All rows are re-rendered when the `view` or `path_opts` change (their
  label badges link to the view with the label added, see
  `SentinelixWeb.DashboardLive.view_path/2`, and the layout may have
  changed) or when rows changed places (a rename).
  """

  use SentinelixWeb, :live_component

  import SentinelixWeb.MonitorComponents

  alias Sentinelix.Monitoring.{Grouping, History, Selector}
  alias SentinelixWeb.DashboardLive

  @heartbeats 50

  @doc "The number of heartbeats shown per monitor."
  @spec heartbeats() :: pos_integer()
  def heartbeats, do: @heartbeats

  @impl true
  def mount(socket) do
    {:ok, stream_configure(socket, :rows, dom_id: &"monitor-#{&1.id}")}
  end

  @impl true
  def update_many(assigns_sockets) do
    plans =
      Enum.map(assigns_sockets, fn {assigns, socket} ->
        {assigns, socket, plan(assigns, socket)}
      end)

    results =
      plans
      |> Enum.filter(fn {assigns, _socket, _plan} -> assigns.view.layout == :list end)
      |> Enum.flat_map(fn {_assigns, _socket, {_kind, entries, _deleted}} -> entries end)
      |> Enum.map(& &1.monitor.id)
      |> recent_results()

    Enum.map(plans, fn {assigns, socket, plan} -> apply_plan(socket, assigns, plan, results) end)
  end

  # What to stream: `{:reset, entries, []}` or `{:patch, changed, deleted_ids}`.
  defp plan(assigns, socket) do
    entries = assigns.entries
    ids = Enum.map(entries, & &1.monitor.id)

    case socket.assigns do
      %{view: view, path_opts: path_opts, ids: old_ids, rendered: rendered}
      when view == assigns.view and path_opts == assigns.path_opts ->
        kept = MapSet.new(ids)
        old = MapSet.new(old_ids)

        if Enum.filter(ids, &MapSet.member?(old, &1)) ==
             Enum.filter(old_ids, &MapSet.member?(kept, &1)) do
          changed = Enum.reject(entries, &(Map.get(rendered, &1.monitor.id) == &1))
          {:patch, changed, Enum.reject(old_ids, &MapSet.member?(kept, &1))}
        else
          {:reset, entries, []}
        end

      _first_or_new_view ->
        {:reset, entries, []}
    end
  end

  defp apply_plan(socket, assigns, {kind, entries, deleted}, results) do
    socket =
      socket
      |> assign(Map.take(assigns, [:id, :dom_id, :view, :path_opts]))
      |> assign(
        ids: Enum.map(assigns.entries, & &1.monitor.id),
        rendered: Map.new(assigns.entries, &{&1.monitor.id, &1})
      )

    rows = Enum.map(entries, &build_row(&1, Map.get(results, &1.monitor.id, [])))

    case kind do
      :reset ->
        stream(socket, :rows, rows, reset: true)

      :patch ->
        positions = socket.assigns.ids |> Enum.with_index() |> Map.new()

        socket =
          Enum.reduce(deleted, socket, &stream_delete_by_dom_id(&2, :rows, "monitor-#{&1}"))

        # New rows at their place, changed ones are updated where they are.
        rows
        |> Enum.sort_by(&positions[&1.id])
        |> Enum.reduce(socket, &stream_insert(&2, :rows, &1, at: positions[&1.id]))
    end
  end

  defp build_row(entry, results) do
    Map.merge(entry, %{
      id: entry.monitor.id,
      results: results,
      uptime: Grouping.uptime(Map.get(entry, :checks))
    })
  end

  defp recent_results([]), do: %{}
  defp recent_results(ids), do: History.recent_results_by_monitor(@heartbeats, ids)

  @impl true
  def render(%{view: %{layout: :grid}} = assigns) do
    ~H"""
    <div
      id={@dom_id}
      phx-update="stream"
      class="grid grid-cols-[repeat(auto-fill,minmax(9rem,1fr))] gap-1.5 p-3"
    >
      <.monitor_tile
        :for={{dom_id, row} <- @streams.rows}
        id={dom_id}
        monitor={row.monitor}
        status={row.status}
        response_time_ms={row.latest && row.latest.response_time_ms}
        uptime={row.uptime}
        warning={row.warning}
        maintenance={row.maintenance}
      />
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id={@dom_id} phx-update="stream" class="divide-y divide-base-300">
      <div
        :for={{dom_id, row} <- @streams.rows}
        id={dom_id}
        class="flex flex-col gap-3 px-4 py-3 transition hover:bg-base-200/50 md:flex-row md:items-center"
      >
        <div class="flex min-w-0 flex-1 items-center gap-3">
          <span
            class={[
              "badge badge-sm w-16 shrink-0 justify-center font-semibold tabular-nums",
              uptime_class(row.uptime)
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
                patch={&DashboardLive.add_term_path(@view, Selector.label_term(&1), @path_opts)}
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
    """
  end
end
