defmodule SentinelixWeb.WallLive do
  @moduledoc """
  A wall or kiosk display (`/wall/<token>`): the saved views of a display
  token (`Sentinelix.DisplayTokens`) full screen, without a login or any
  navigation, readable from across the room. The token is checked by
  `SentinelixWeb.WallAuth` (on the page load and every mount, so also on
  every reconnect).

  ## What it shows

  Per monitor only its **name, status, latest response time and 24h
  uptime** (and whether it has a warning or is in maintenance, as icons).
  Never targets, settings, labels, selectors, check or maintenance
  messages. The assigns only hold this sanitized data: the monitor index
  (`SentinelixWeb.MonitorIndex`, whole monitors) and the views' selectors
  are kept in the socket's private data, which is never rendered.

  The one exception is how the view groups monitors: a grouped view shows
  its groups under the **values** of the group-by labels (`oslo`, not
  `site=oslo`), and a matrix view its rows and columns, because that's
  what the view's owner chose to show. No other labels are shown.

  Each view is shown by its layout:

    * `list` – large tiles (`SentinelixWeb.MonitorComponents.monitor_tile/1`,
      `size="lg"`) with status, response time and uptime,
    * `grid` – small tiles with the name, for many monitors on a screen,
    * `matrix` – the matrix of the two group-by keys, large cells.

  Tiles and cells don't link anywhere.

  ## Rotation and updates

  With several views and a rotation (`rotate_seconds`), the display
  switches to the next view every so many seconds. Statuses update live;
  changing the token or a saved view updates the display, revoking the
  token disconnects it (a redirect to its URL, which is a 404 then). Every
  `@recheck_ms` it also checks the token again (expiry, the creator's
  access to the views).

  ## Connection loss

  LiveView reconnects by itself (and the token is in the URL, so the
  reconnect mounts again with it). While disconnected a banner says so
  and the content is dimmed, so a stale screen isn't taken for a green
  one. Server errors during a reconnect reload the page after a while
  (`SentinelixWeb.ErrorHTML`).
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents

  alias Sentinelix.{DisplayTokens, SavedViews}
  alias Sentinelix.Monitoring.{Grouping, Selector, View}
  alias SentinelixWeb.MonitorIndex

  @recheck_ms Application.compile_env(:sentinelix, [__MODULE__, :recheck_ms], 30_000)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="wall" class="flex min-h-screen flex-col bg-base-200/40 text-base-content">
      <div
        id="wall-disconnected"
        role="alert"
        hidden
        phx-disconnected={
          JS.remove_attribute("hidden") |> JS.add_class("opacity-30 grayscale", to: "#wall-content")
        }
        phx-connected={
          JS.set_attribute({"hidden", ""})
          |> JS.remove_class("opacity-30 grayscale", to: "#wall-content")
        }
        class="fixed inset-x-0 top-0 z-50 flex items-center justify-center gap-3 bg-error px-6 py-4 text-2xl font-semibold text-error-content shadow-lg"
      >
        <.icon name="hero-signal-slash" class="size-8 shrink-0" />
        Connection lost, reconnecting… The statuses shown may be out of date.
      </div>

      <header class="flex flex-wrap items-center gap-x-6 gap-y-2 border-b border-base-300 bg-base-100 px-6 py-4">
        <h1 id="wall-title" class="min-w-0 flex-1 truncate text-3xl font-semibold tracking-tight">
          {@title}
        </h1>
        <div id="wall-summary" class="flex flex-wrap items-center gap-3 text-2xl font-semibold">
          <span :if={@total > 0 and @problems == []} class="flex items-center gap-2 text-success">
            <.status_icon status={:up} class="size-8" /> All {@total} up
          </span>
          <span
            :for={{status, count} <- @problems}
            class={["flex items-center gap-2", status_text_class(status)]}
            data-status={status}
          >
            <.status_icon status={status} class="size-8" />
            {count} {String.downcase(status_label(status))}
          </span>
        </div>
        <div
          :if={length(@views) > 1}
          id="wall-rotation"
          class="flex items-center gap-1.5"
          aria-label={"View #{@current + 1} of #{length(@views)}"}
        >
          <span
            :for={{view, index} <- Enum.with_index(@views)}
            title={view.name}
            class={[
              "size-3 rounded-full",
              if(index == @current, do: "bg-base-content", else: "bg-base-content/25")
            ]}
          />
        </div>
        <div class="flex items-center gap-2 opacity-40 transition hover:opacity-100">
          <button
            type="button"
            id="wall-fullscreen"
            phx-click={JS.dispatch("sentinelix:fullscreen")}
            class="btn btn-ghost btn-sm btn-square"
            title="Full screen"
          >
            <.icon name="hero-arrows-pointing-out" class="size-5" />
          </button>
          <Layouts.theme_toggle />
        </div>
      </header>

      <main id="wall-content" class="flex-1 space-y-6 p-6 transition">
        <p :if={@message} id="wall-message" class="py-24 text-center text-3xl text-base-content/60">
          {@message}
        </p>

        <.matrix :if={@matrix} matrix={@matrix} />

        <section
          :for={{section, index} <- Enum.with_index(@sections)}
          :key={section.key}
          id={"wall-section-#{index}"}
          class="space-y-3"
        >
          <.section_header :if={section.title} section={section} />
          <div :if={section.groups != []} class="space-y-4 pl-2">
            <div
              :for={{child, child_index} <- Enum.with_index(section.groups)}
              :key={child.key}
              id={"wall-section-#{index}-#{child_index}"}
              class="space-y-2"
            >
              <.section_header section={child} nested />
              <.tiles tiles={child.tiles} size={@tile_size} />
            </div>
          </div>
          <.tiles :if={section.groups == []} tiles={section.tiles} size={@tile_size} />
        </section>
      </main>
    </div>
    """
  end

  attr :section, :map, required: true
  attr :nested, :boolean, default: false

  defp section_header(assigns) do
    ~H"""
    <h2 class={[
      "flex items-center gap-3 font-semibold",
      if(@nested, do: "text-xl", else: "text-2xl")
    ]}>
      <span class={status_text_class(@section.worst)}>
        <.status_icon status={@section.worst} class={if @nested, do: "size-6", else: "size-7"} />
      </span>
      <span class={["truncate", @section.title == :none && "italic opacity-60"]}>
        {if @section.title == :none, do: "(none)", else: @section.title}
      </span>
      <span class="text-base font-normal tabular-nums text-base-content/60">
        {@section.up}/{@section.total} up · {format_uptime(@section.uptime)}
      </span>
    </h2>
    """
  end

  attr :tiles, :list, required: true
  attr :size, :string, required: true

  defp tiles(assigns) do
    ~H"""
    <div class={[
      "grid gap-2",
      if(@size == "lg",
        do: "grid-cols-[repeat(auto-fill,minmax(16rem,1fr))]",
        else: "grid-cols-[repeat(auto-fill,minmax(10rem,1fr))]"
      )
    ]}>
      <.monitor_tile
        :for={tile <- @tiles}
        :key={tile.monitor.id}
        id={"tile-#{tile.monitor.id}"}
        monitor={tile.monitor}
        status={tile.status}
        response_time_ms={tile.response_time_ms}
        uptime={tile.uptime}
        warning={tile.warning}
        maintenance={if tile.maintenance, do: [:active], else: []}
        size={@size}
        navigate={false}
      />
    </div>
    """
  end

  attr :matrix, :map, required: true

  defp matrix(assigns) do
    ~H"""
    <div id="wall-matrix" class="overflow-x-auto">
      <table class="border-separate border-spacing-2 text-xl">
        <thead>
          <tr>
            <th></th>
            <th
              :for={column <- @matrix.columns}
              :key={column.key}
              scope="col"
              class="px-2 text-center font-semibold"
            >
              <span class={["inline-flex items-center gap-2", status_text_class(column.worst)]}>
                <.status_icon status={column.worst} class="size-6" />
              </span>
              <.title title={column.title} />
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @matrix.rows} :key={row.key}>
            <th scope="row" class="whitespace-nowrap pr-3 text-left font-semibold">
              <span class={["inline-flex items-center gap-2", status_text_class(row.worst)]}>
                <.status_icon status={row.worst} class="size-6" />
              </span>
              <.title title={row.title} />
            </th>
            <td :for={cell <- row.cells} class="p-0">
              <div
                :if={cell}
                data-status={cell.worst}
                class={[
                  "flex h-16 min-w-28 items-center justify-center gap-2 rounded-field border px-3 text-2xl font-semibold tabular-nums",
                  status_tile_class(cell.worst)
                ]}
              >
                <span class={cell.worst != :down && status_text_class(cell.worst)}>
                  <.status_icon status={cell.worst} class="size-7" />
                </span>
                <span class="sr-only">{status_label(cell.worst)}:</span>
                {cell.count}
              </div>
              <div
                :if={!cell}
                class="flex h-16 min-w-28 items-center justify-center rounded-field border border-dashed border-base-300 text-base-content/30"
              >
                <span aria-hidden="true">–</span>
                <span class="sr-only">No monitors</span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :title, :any, required: true

  defp title(%{title: :none} = assigns), do: ~H|<span class="italic opacity-60">(none)</span>|
  defp title(assigns), do: ~H|<span>{@title}</span>|

  ## Lifecycle

  @impl true
  def mount(_params, _session, socket) do
    display_token = socket.assigns.display_token
    index = MonitorIndex.load()

    if connected?(socket) do
      MonitorIndex.subscribe(index)
      SavedViews.subscribe()
      DisplayTokens.subscribe(display_token)
      Process.send_after(self(), :recheck, @recheck_ms)
    end

    socket =
      socket
      |> put_private(:wall_index, index)
      |> put_private(:wall_rotation_timer, nil)
      |> assign(current: 0, views: [])
      |> load_views()

    {:ok, socket}
  end

  @impl true
  def handle_info(:rotate, socket) do
    count = length(socket.assigns.views)
    current = if count > 0, do: rem(socket.assigns.current + 1, count), else: 0

    {:noreply,
     socket
     |> assign(current: current)
     |> put_private(:wall_rotation_timer, nil)
     |> ensure_rotation()
     |> assign_display()}
  end

  def handle_info(:recheck, socket) do
    Process.send_after(self(), :recheck, @recheck_ms)
    reload_token(socket)
  end

  def handle_info({:display_token_changed}, socket), do: reload_token(socket)
  def handle_info({:display_token_revoked}, socket), do: {:noreply, disconnect(socket)}
  def handle_info({:saved_views_changed}, socket), do: {:noreply, load_views(socket)}

  def handle_info(message, socket) do
    case MonitorIndex.handle_message(socket.private.wall_index, message) do
      {:ok, index} -> {:noreply, socket |> put_private(:wall_index, index) |> assign_display()}
      :ignore -> {:noreply, socket}
    end
  end

  defp reload_token(socket) do
    case DisplayTokens.get_valid_token(socket.assigns.display_token.id) do
      {:ok, display_token} ->
        {:noreply, socket |> assign(display_token: display_token) |> load_views()}

      :error ->
        {:noreply, disconnect(socket)}
    end
  end

  # The token is gone: reloading the page shows the 404 any invalid token
  # gets (see SentinelixWeb.WallAuth).
  defp disconnect(socket), do: redirect(socket, to: socket.private.wall_path)

  ## Views

  # The views the token shows now, keeping the one shown if it's still
  # there.
  defp load_views(socket) do
    shown = Enum.at(socket.assigns.views, socket.assigns.current)

    views =
      socket.assigns.display_token
      |> DisplayTokens.display_views()
      |> Enum.map(fn saved ->
        view =
          case SavedViews.to_view(saved) do
            {:ok, view} -> view
            {:error, view, _text, _error} -> view
          end

        %{id: saved.id, name: saved.name, view: view}
      end)

    current = (shown && Enum.find_index(views, &(&1.id == shown.id))) || 0

    socket
    |> put_private(:wall_views, Map.new(views, &{&1.id, &1.view}))
    |> assign(views: Enum.map(views, &Map.take(&1, [:id, :name])), current: current)
    |> ensure_rotation()
    |> assign_display()
  end

  # Keeps a rotation timer running while there are views to rotate
  # through (a running one is left alone, so reloading the views doesn't
  # hold up the rotation).
  defp ensure_rotation(socket) do
    timer = socket.private.wall_rotation_timer
    seconds = socket.assigns.display_token.rotate_seconds
    rotates? = connected?(socket) and seconds != nil and length(socket.assigns.views) > 1

    cond do
      rotates? and timer ->
        socket

      rotates? ->
        put_private(
          socket,
          :wall_rotation_timer,
          Process.send_after(self(), :rotate, seconds * 1000)
        )

      timer ->
        Process.cancel_timer(timer)
        put_private(socket, :wall_rotation_timer, nil)

      true ->
        socket
    end
  end

  ## What is shown

  # Only sanitized data goes into the assigns, see the module docs.
  defp assign_display(socket) do
    case Enum.at(socket.assigns.views, socket.assigns.current) do
      nil ->
        socket
        |> assign(title: "Sentinelix", page_title: "Wall display")
        |> assign_empty("Nothing to show: this display's views aren't available.")

      %{id: id, name: name} ->
        view = Map.fetch!(socket.private.wall_views, id)
        socket = assign(socket, title: name, page_title: name)
        assign_view(socket, view)
    end
  end

  defp assign_view(socket, %View{selector: nil}),
    do: assign_empty(socket, "This view's filter is invalid. Fix it in Sentinelix.")

  defp assign_view(socket, %View{selector: selector} = view) do
    entries =
      socket.private.wall_index
      |> Map.values()
      |> Enum.filter(&Selector.matches?(selector, &1.monitor, status: &1.status))

    socket =
      assign(socket,
        total: length(entries),
        problems: problems(entries),
        tile_size: if(view.layout == :grid, do: "sm", else: "lg"),
        message: if(entries == [], do: "No monitors in this view.")
      )

    if View.matrix?(view) do
      %{rows: rows, columns: columns} = Grouping.matrix(entries, view.group_by, sort: view.sort)
      assign(socket, matrix: matrix_rows(rows, columns), sections: [])
    else
      groups = Grouping.group(entries, view.group_by, sort: view.sort)
      assign(socket, matrix: nil, sections: Enum.map(groups, &section/1))
    end
  end

  defp assign_empty(socket, message) do
    assign(socket,
      total: 0,
      problems: [],
      tile_size: "lg",
      message: message,
      matrix: nil,
      sections: []
    )
  end

  # Statuses other than up that monitors are in, worst first.
  defp problems(entries) do
    counts = Enum.frequencies_by(entries, & &1.status)

    for status <- Grouping.severity(),
        status != :up,
        (counts[status] || 0) > 0,
        do: {status, counts[status]}
  end

  # `key` only keys the comprehensions (it isn't rendered): the group ids
  # are made of label keys and values.
  defp section(%Grouping.Group{} = group) do
    %{
      key: group.id,
      title: group_title(group),
      worst: group.worst,
      up: group.counts.up,
      total: group.total,
      uptime: group.uptime,
      groups: Enum.map(group.groups, &section/1),
      tiles: if(group.groups == [], do: Enum.map(group.entries, &tile/1), else: [])
    }
  end

  defp tile(entry) do
    %{
      monitor: %{id: entry.monitor.id, name: entry.monitor.name},
      status: entry.status,
      response_time_ms: entry.latest && entry.latest.response_time_ms,
      uptime: Grouping.uptime(entry.checks),
      warning: entry.warning,
      maintenance: entry.maintenance != []
    }
  end

  # The single group of an ungrouped view has no title; "(none)" is :none,
  # a label without a value shows its key.
  defp group_title(%Grouping.Group{key: nil}), do: nil
  defp group_title(%Grouping.Group{value: nil}), do: :none
  defp group_title(%Grouping.Group{key: key, value: ""}), do: key
  defp group_title(%Grouping.Group{value: value}), do: value

  defp matrix_rows(rows, columns) do
    %{
      columns: Enum.map(columns, &matrix_header/1),
      rows:
        Enum.map(rows, fn row ->
          row
          |> matrix_header()
          |> Map.put(:cells, Enum.map(columns, &matrix_cell(Grouping.cell(row, &1))))
        end)
    }
  end

  defp matrix_header(group), do: %{key: group.id, title: group_title(group), worst: group.worst}

  defp matrix_cell(nil), do: nil

  # "1/3" in the worst status, or how many when they're all up.
  defp matrix_cell(cell) do
    count =
      if cell.worst == :up,
        do: "#{cell.total}",
        else: "#{cell.counts[cell.worst]}/#{cell.total}"

    %{worst: cell.worst, count: count}
  end
end
