defmodule SentinelixWeb.MaintenanceLive.Index do
  @moduledoc """
  Maintenance windows (`/maintenance`): all windows with their schedule,
  monitors and current state; enable/disable and delete.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents

  alias Sentinelix.Maintenance
  alias Sentinelix.Maintenance.Window

  @weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:maintenance}>
      <.header>
        Maintenance windows
        <:subtitle>
          Planned work: checks keep running but monitors don't alert during a window.
        </:subtitle>
        <:actions>
          <.button navigate={~p"/maintenance/new"} variant="primary" id="new-window">
            <.icon name="hero-plus" class="size-4" /> New window
          </.button>
        </:actions>
      </.header>

      <div
        :if={@windows == []}
        id="no-windows"
        class="rounded-box border border-dashed border-base-300 bg-base-100 px-6 py-16 text-center"
      >
        <.icon name="hero-wrench-screwdriver" class="mx-auto size-10 text-base-content/30" />
        <h3 class="mt-3 text-lg font-semibold">No maintenance windows</h3>
        <p class="mt-1 text-sm text-base-content/60">
          Schedule one-off or recurring windows to silence alerts during planned work.
        </p>
      </div>

      <div :if={@windows != []} class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table class="table">
          <thead>
            <tr>
              <th>Title</th>
              <th class="hidden md:table-cell">Schedule</th>
              <th class="hidden sm:table-cell">Monitors</th>
              <th>Status</th>
              <th><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody id="windows">
            <tr :for={window <- @windows} id={"window-#{window.id}"} class="hover:bg-base-200/50">
              <td class="max-w-64">
                <.link
                  navigate={~p"/maintenance/#{window.id}/edit"}
                  class="block truncate font-medium hover:underline"
                >
                  {window.title}
                </.link>
                <p :if={window.description} class="truncate text-xs text-base-content/60">
                  {window.description}
                </p>
              </td>
              <td class="hidden text-sm md:table-cell">
                {schedule_summary(window)}
                <div class="text-xs text-base-content/60">{window.timezone}</div>
              </td>
              <td class="hidden max-w-56 text-sm sm:table-cell">
                <span :if={window.all_monitors} class="badge badge-ghost badge-sm">All monitors</span>
                <code
                  :if={!window.all_monitors and window.selector != ""}
                  id={"window-selector-#{window.id}"}
                  class="block truncate font-mono text-xs"
                  title={"Monitors matching #{window.selector}"}
                >
                  {window.selector}
                </code>
                <span
                  :if={!window.all_monitors and (window.selector == "" or window.monitors != [])}
                  class="block truncate"
                  title={monitor_names(window)}
                >
                  {if window.selector != "", do: "+ "}{monitor_names(window)}
                </span>
              </td>
              <td>
                <.window_status id={"window-status-#{window.id}"} window={window} now={@now} />
              </td>
              <td>
                <div class="flex justify-end gap-1">
                  <button
                    type="button"
                    phx-click="toggle"
                    phx-value-id={window.id}
                    class="btn btn-ghost btn-xs"
                    title={if window.enabled, do: "Disable", else: "Enable"}
                    id={"toggle-window-#{window.id}"}
                  >
                    <.icon :if={window.enabled} name="hero-pause" class="size-4" />
                    <.icon :if={!window.enabled} name="hero-play" class="size-4" />
                  </button>
                  <.link
                    navigate={~p"/maintenance/#{window.id}/edit"}
                    class="btn btn-ghost btn-xs"
                    title="Edit"
                    id={"edit-window-#{window.id}"}
                  >
                    <.icon name="hero-pencil-square" class="size-4" />
                  </.link>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={window.id}
                    data-confirm={"Delete the maintenance window \"#{window.title}\"?"}
                    class="btn btn-ghost btn-xs text-error"
                    title="Delete"
                    id={"delete-window-#{window.id}"}
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :window, Window, required: true
  attr :now, DateTime, required: true

  defp window_status(assigns) do
    assigns =
      assign(assigns,
        status: Window.status(assigns.window, assigns.now),
        occurrence: Window.next_occurrence(assigns.window, assigns.now)
      )

    ~H"""
    <div id={@id} class="flex flex-col items-start gap-1">
      <span class={["badge badge-sm", window_status_class(@status)]}>{window_status_label(@status)}</span>
      <span :if={@status == :active} class="text-xs text-base-content/60">
        until <.local_time id={"#{@id}-until"} at={elem(@occurrence, 1)} />
      </span>
      <span :if={@status == :scheduled} class="text-xs text-base-content/60">
        next <.local_time id={"#{@id}-next"} at={elem(@occurrence, 0)} />
      </span>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Maintenance.subscribe()
    {:ok, socket |> assign(page_title: "Maintenance") |> load()}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    with %Window{} = window <- get_window(id),
         {:ok, window} <- Maintenance.update_window(window, %{enabled: !window.enabled}) do
      verb = if window.enabled, do: "enabled", else: "disabled"
      {:noreply, socket |> put_flash(:info, "#{window.title} #{verb}.") |> load()}
    else
      _ -> {:noreply, socket |> put_flash(:error, "Could not update the window.") |> load()}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Window{} = window <- get_window(id),
         {:ok, window} <- Maintenance.delete_window(window) do
      {:noreply, socket |> put_flash(:info, "#{window.title} deleted.") |> load()}
    else
      _ -> {:noreply, socket |> put_flash(:error, "Could not delete the window.") |> load()}
    end
  end

  @impl true
  def handle_info({:maintenance_changed}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    assign(socket, windows: Maintenance.list_windows(), now: DateTime.utc_now())
  end

  defp get_window(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Maintenance.get_window(id)
      _ -> nil
    end
  end

  ## Formatting

  @doc """
  A short description of a window's schedule, in its time zone.
  """
  @spec schedule_summary(Window.t()) :: String.t()
  def schedule_summary(%Window{recurrence: :once} = window) do
    "#{format_local(window.starts_at, window.timezone)} – #{format_local(window.ends_at, window.timezone)}"
  end

  def schedule_summary(%Window{} = window) do
    days =
      case window.recurrence do
        :daily -> "Daily"
        :weekly -> Enum.map_join(window.weekdays, ", ", &Enum.at(@weekdays, &1 - 1))
      end

    base =
      "#{days} at #{Calendar.strftime(window.start_time, "%H:%M")} for " <>
        format_duration((window.duration_minutes || 0) * 60)

    base <> bounds(window)
  end

  defp bounds(%{starts_at: nil, ends_at: nil}), do: ""

  defp bounds(window) do
    from = window.starts_at && " from #{format_local(window.starts_at, window.timezone)}"
    until = window.ends_at && " until #{format_local(window.ends_at, window.timezone)}"
    "#{from}#{until}"
  end

  defp format_local(nil, _tz), do: "–"

  defp format_local(at, tz) do
    case DateTime.shift_zone(at, tz) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M")
      _ -> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
    end
  end

  defp monitor_names(%Window{monitors: monitors}) when is_list(monitors) do
    case monitors do
      [] -> "–"
      monitors -> monitors |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join(", ")
    end
  end

  defp monitor_names(_window), do: "–"

  defp window_status_label(:active), do: "Active"
  defp window_status_label(:scheduled), do: "Scheduled"
  defp window_status_label(:ended), do: "Ended"
  defp window_status_label(:disabled), do: "Disabled"

  defp window_status_class(:active), do: "badge-info"
  defp window_status_class(:scheduled), do: "badge-ghost"
  defp window_status_class(_status), do: "badge-ghost opacity-60"
end
