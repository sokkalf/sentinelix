defmodule SentinelixWeb.DashboardLive.Matrix do
  @moduledoc """
  The dashboard's matrix layout: the values of the view's first group-by
  key as rows and of the second as columns (`service` × `site`), a cell
  per combination with the worst status of its monitors and how many are
  in it (see `Sentinelix.Monitoring.Grouping.matrix/3`). Answers "is it
  everywhere or only in Helsinki?".

  Columns are the union of the values of all rows, so a combination
  without monitors is an empty cell. A cell, a row header or a column
  header links to the list of its monitors (`filter_view/2`); the browser's
  back button returns to the matrix.

  The matrix is rendered by the dashboard itself, its rows and cells as
  keyed comprehensions: a status change sends only the cells (and headers)
  that changed. It renders no monitors, so it stays small with hundreds of
  them.

  Cells show the counts per status and the uptime on hover and keyboard
  focus. The table isn't in a scrolling box, which would clip those
  details; a matrix wider than the page scrolls the page.
  """

  use SentinelixWeb, :html

  import SentinelixWeb.MonitorComponents

  alias Sentinelix.Monitoring.{Grouping, Selector, View}
  alias Sentinelix.Monitoring.Grouping.Group
  alias SentinelixWeb.DashboardLive

  @doc """
  The view of the monitors of matrix groups (a cell, or a row and a
  column): the view's selector with a term for each group's label, as a
  list without grouping. A "(none)" group adds a `!key` term.
  """
  @spec filter_view(View.t(), [Group.t()]) :: View.t()
  def filter_view(%View{} = view, groups) do
    selector =
      Enum.reduce(groups, view.selector || %Selector{}, &Selector.add(&2, group_term(&1)))

    %{view | selector: selector, group_by: [], layout: :list}
  end

  defp group_term(%Group{key: key, value: nil}), do: %Selector.Term{key: key, op: :absent}
  defp group_term(%Group{key: key, value: value}), do: Selector.label_term({key, value})

  @doc """
  The matrix of `rows` (with their cells as nested groups) and `columns`,
  as `Sentinelix.Monitoring.Grouping.matrix/3` returns them.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :columns, :list, required: true
  attr :view, View, required: true

  def matrix(assigns) do
    [row_key, column_key] = assigns.view.group_by
    assigns = assign(assigns, row_key: row_key, column_key: column_key)

    ~H"""
    <div id={@id} class="p-3">
      <table class="w-max border-separate border-spacing-1 text-sm">
        <caption class="sr-only">
          Monitors by {@row_key} (rows) and {@column_key} (columns): the worst status
          and the number of monitors of each combination
        </caption>
        <thead>
          <tr>
            <th scope="col" class="px-2 text-left font-mono text-xs font-medium opacity-60">
              {@row_key} \ {@column_key}
            </th>
            <th
              :for={column <- @columns}
              :key={column.id}
              scope="col"
              class="px-1 align-bottom font-normal"
              data-column={column.id}
            >
              <.header_link group={column} view={@view} class="justify-center" />
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} :key={row.id} data-row={row.id}>
            <th scope="row" class="pr-2 text-left font-normal">
              <.header_link group={row} view={@view} />
            </th>
            <td :for={column <- @columns} :key={column.id} class="p-0">
              <.cell
                cell={Grouping.cell(row, column)}
                row={row}
                column={column}
                view={@view}
              />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :group, Group, required: true
  attr :view, View, required: true
  attr :class, :any, default: nil

  # A row or column header: its value and worst status, linking to its
  # monitors.
  defp header_link(assigns) do
    ~H"""
    <.link
      patch={DashboardLive.view_path(filter_view(@view, [@group]))}
      class={[
        "flex items-center gap-1.5 rounded-field px-1 py-0.5 hover:bg-base-200",
        "focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content",
        @class
      ]}
      title={"#{@group.counts.up}/#{@group.total} up"}
    >
      <span class={status_text_class(@group.worst)}>
        <.status_icon status={@group.worst} class="size-4" />
      </span>
      <span class="sr-only">{status_label(@group.worst)}:</span>
      <span class="whitespace-nowrap font-mono text-xs"><.value group={@group} /></span>
    </.link>
    """
  end

  attr :cell, Group, default: nil
  attr :row, Group, required: true
  attr :column, Group, required: true
  attr :view, View, required: true

  defp cell(%{cell: nil} = assigns) do
    ~H"""
    <div
      class="flex h-9 min-w-16 items-center justify-center rounded-field border border-dashed border-base-300 text-base-content/30"
      data-empty
    >
      <span aria-hidden="true">–</span>
      <span class="sr-only">No monitors</span>
    </div>
    """
  end

  defp cell(assigns) do
    worst = assigns.cell.worst

    assigns =
      assign(assigns,
        dom_id: "cell-" <> Base.url_encode64(assigns.cell.id, padding: false),
        worst: worst,
        # "1/3" in the worst status, or all of them when they're all up.
        count:
          if(worst == :up,
            do: "#{assigns.cell.total}",
            else: "#{assigns.cell.counts[worst]}/#{assigns.cell.total}"
          ),
        statuses: Enum.filter(Grouping.severity(), &(assigns.cell.counts[&1] > 0))
      )

    ~H"""
    <.link
      id={@dom_id}
      patch={DashboardLive.view_path(filter_view(@view, [@row, @column]))}
      aria-describedby={@dom_id <> "-details"}
      data-cell={@cell.id}
      data-status={@worst}
      class={[
        "group/cell relative flex h-9 min-w-16 items-center justify-center gap-1 rounded-field border px-2",
        "font-semibold tabular-nums transition hover:brightness-95",
        "focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content focus-visible:ring-offset-1",
        status_tile_class(@worst)
      ]}
    >
      <span class={@worst != :down && status_text_class(@worst)}>
        <.status_icon status={@worst} class="size-4" />
      </span>
      <span class="sr-only">
        <.value group={@row} />, <.value group={@column} />: {status_label(@worst)},
      </span>
      {@count}
      <span
        id={@dom_id <> "-details"}
        role="tooltip"
        class={[
          "pointer-events-none absolute bottom-full left-1/2 z-20 mb-1 hidden w-48 -translate-x-1/2",
          "rounded-box border border-base-300 bg-base-100 p-2 text-left text-xs font-normal text-base-content shadow-lg",
          "group-hover/cell:block group-focus-visible/cell:block"
        ]}
      >
        <span class="block font-mono font-medium">
          <.value group={@row} full />, <.value group={@column} full />
        </span>
        <span
          :for={status <- @statuses}
          class={["flex items-center gap-1", status_text_class(status)]}
        >
          <.status_icon status={status} class="size-3" />
          {@cell.counts[status]} {String.downcase(status_label(status))}
        </span>
        <span class="block">Uptime (24h): {format_uptime(@cell.uptime)}</span>
      </span>
    </.link>
    """
  end

  attr :group, Group, required: true
  attr :full, :boolean, default: false, doc: "as key=value"

  defp value(%{group: %{value: nil}} = assigns) do
    ~H"""
    <span :if={@full}>!{@group.key}</span><span :if={!@full} class="italic">(none)</span>
    """
  end

  defp value(%{group: %{value: ""}} = assigns), do: ~H"{@group.key}"
  defp value(%{full: true} = assigns), do: ~H"{@group.key}={@group.value}"
  defp value(assigns), do: ~H"{@group.value}"
end
