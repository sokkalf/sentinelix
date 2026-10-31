defmodule SentinelixWeb.MonitorLive.Index do
  @moduledoc """
  Monitor management: all monitors in a table with their configuration and
  actions (pause/resume, edit, clone, delete).

  ## Bulk actions

  Monitors are selected with the row checkboxes, or all monitors matching
  the list's current filter at once. The selection is a set of ids and
  never contains monitors that don't match the filter: when the filter
  changes or a monitor stops matching, it is deselected, so a bulk action
  only changes monitors that are shown. Monitors that start matching later
  are not selected automatically.

  Each action (add or remove labels, pause or resume, attach or detach a
  notification channel, delete) is one context call that changes all
  selected monitors at once, see "Bulk changes" in `Sentinelix.Monitoring`.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents

  alias Sentinelix.{Maintenance, Monitoring, Notifications}
  alias Sentinelix.Monitoring.Labels

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

        <.bulk_actions
          :if={MapSet.size(@selected) > 0}
          selected={MapSet.size(@selected)}
          matching={MapSet.size(@matching)}
          filtered={@q != ""}
          channels={@channels}
          label_options={@label_options}
        />

        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th class="w-0">
                  <input
                    type="checkbox"
                    id="select-all"
                    class="checkbox checkbox-sm"
                    phx-click={if all_selected?(assigns), do: "clear_selection", else: "select_all"}
                    checked={all_selected?(assigns)}
                    disabled={MapSet.size(@matching) == 0}
                    aria-label={if @q == "", do: "Select all", else: "Select all matching"}
                  />
                </th>
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
                <td colspan="7" class="py-10 text-center text-base-content/60">
                  {if @count == 0, do: "No monitors yet.", else: "No monitors match your search."}
                </td>
              </tr>
              <tr :for={{dom_id, row} <- @streams.monitors} id={dom_id} class="hover:bg-base-200/50">
                <td>
                  <input
                    type="checkbox"
                    id={"select-#{row.id}"}
                    class="checkbox checkbox-sm"
                    phx-click="select"
                    phx-value-id={row.id}
                    checked={MapSet.member?(@selected, row.id)}
                    aria-label={"Select #{row.monitor.name}"}
                  />
                </td>
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

  attr :selected, :integer, required: true
  attr :matching, :integer, required: true
  attr :filtered, :boolean, required: true
  attr :channels, :list, required: true
  attr :label_options, :list, required: true

  # The toolbar shown while monitors are selected.
  defp bulk_actions(assigns) do
    ~H"""
    <div
      id="bulk-actions"
      class="flex flex-wrap items-center gap-2 border-b border-base-300 bg-base-200/50 p-3"
    >
      <span id="selection-count" class="text-sm font-medium">
        {pluralize(@selected, "monitor")} selected
      </span>
      <button
        :if={@selected < @matching}
        type="button"
        id="select-all-matching"
        phx-click="select_all"
        class="btn btn-link btn-xs"
      >
        Select all {@matching} {if @filtered, do: "matching", else: "monitors"}
      </button>
      <button
        type="button"
        id="clear-selection"
        phx-click="clear_selection"
        class="btn btn-ghost btn-xs"
      >
        Clear
      </button>

      <div class="flex flex-wrap items-center gap-2 lg:ml-auto">
        <button
          type="button"
          id="bulk-pause"
          phx-click="bulk_enable"
          phx-value-enabled="false"
          class="btn btn-sm"
        >
          <.icon name="hero-pause" class="size-4" /> Pause
        </button>
        <button
          type="button"
          id="bulk-resume"
          phx-click="bulk_enable"
          phx-value-enabled="true"
          class="btn btn-sm"
        >
          <.icon name="hero-play" class="size-4" /> Resume
        </button>

        <form id="bulk-labels-form" phx-submit="bulk_labels" class="join">
          <input
            type="text"
            name="labels"
            list="bulk-label-options"
            placeholder="env=prod site=oslo"
            aria-label="Labels to add or remove"
            autocomplete="off"
            class="input input-sm join-item w-44 font-mono"
          />
          <datalist id="bulk-label-options">
            <option :for={label <- @label_options} value={label} />
          </datalist>
          <button
            type="submit"
            name="op"
            value="add"
            class="btn btn-sm join-item"
            title="Add the labels; key=value replaces the value of an existing key"
          >
            <.icon name="hero-tag" class="size-4" /> Add
          </button>
          <button
            type="submit"
            name="op"
            value="remove"
            class="btn btn-sm join-item"
            title="Remove the labels with these keys"
          >
            Remove
          </button>
        </form>

        <form :if={@channels != []} id="bulk-channels-form" phx-submit="bulk_channels" class="join">
          <select
            name="channel_id"
            aria-label="Notification channel"
            class="select select-sm join-item w-40"
          >
            {Phoenix.HTML.Form.options_for_select(Enum.map(@channels, &{&1.name, &1.id}), nil)}
          </select>
          <button
            type="submit"
            name="op"
            value="attach"
            class="btn btn-sm join-item"
            title="Notify this channel about the selected monitors"
          >
            <.icon name="hero-bell" class="size-4" /> Attach
          </button>
          <button
            type="submit"
            name="op"
            value="detach"
            class="btn btn-sm join-item"
            title="Stop notifying this channel about the selected monitors"
          >
            Detach
          </button>
        </form>

        <button
          type="button"
          id="bulk-delete"
          phx-click="bulk_delete"
          data-confirm={"Delete #{pluralize(@selected, "monitor")} and all of their history?"}
          class="btn btn-sm btn-soft btn-error"
        >
          <.icon name="hero-trash" class="size-4" /> Delete {@selected}
        </button>
      </div>
    </div>
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
      |> assign(page_title: "Monitors", q: "", selected: MapSet.new(), matching: MapSet.new())
      |> assign(channels: Notifications.list_channels())
      |> assign_label_options()
      |> stream_configure(:monitors, dom_id: &"monitor-#{&1.id}")
      |> load()

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(q: String.trim(q)) |> load()}
  end

  def handle_event("select", %{"id" => id}, socket) do
    case get_monitor(id) do
      nil ->
        {:noreply, socket}

      monitor ->
        selected = socket.assigns.selected

        selected =
          if MapSet.member?(selected, monitor.id),
            do: MapSet.delete(selected, monitor.id),
            else: MapSet.put(selected, monitor.id)

        # Re-rendered, so the checkbox shows the selection as the server has it.
        {:noreply,
         socket |> assign(selected: selected) |> upsert(monitor, current_status(monitor))}
    end
  end

  def handle_event("select_all", _params, socket) do
    {:noreply, socket |> assign(selected: socket.assigns.matching) |> load()}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, socket |> assign(selected: MapSet.new()) |> load()}
  end

  def handle_event("bulk_enable", %{"enabled" => enabled}, socket) do
    enabled = enabled == "true"

    case Monitoring.set_monitors_enabled(selected_ids(socket), enabled) do
      {:ok, _changed} ->
        verb = if enabled, do: "resumed", else: "paused"
        {:noreply, put_flash(socket, :info, "#{selection_text(socket)} #{verb}.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, bulk_error(changeset))}
    end
  end

  def handle_event("bulk_labels", %{"labels" => text} = params, socket) do
    # Labels contain neither whitespace nor commas.
    labels = String.split(text, [" ", ",", "\t", "\n"], trim: true)

    result =
      case {params["op"], labels} do
        {_op, []} -> {:error, "Enter labels such as env=prod, or the keys to remove."}
        {"remove", labels} -> remove_labels(socket, labels)
        {_add, labels} -> add_labels(socket, labels)
      end

    case result do
      {:ok, message} -> {:noreply, socket |> put_flash(:info, message) |> assign_label_options()}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("bulk_channels", %{"channel_id" => id} = params, socket) do
    case {Enum.find(socket.assigns.channels, &(to_string(&1.id) == id)), params["op"]} do
      {nil, _op} ->
        {:noreply, put_flash(socket, :error, "Pick a notification channel.")}

      {channel, "detach"} ->
        :ok = Notifications.detach_channels(selected_ids(socket), [channel])
        message = "Detached #{channel.name} from #{selection_text(socket)}."
        {:noreply, put_flash(socket, :info, message)}

      {channel, _attach} ->
        :ok = Notifications.attach_channels(selected_ids(socket), [channel])
        message = "Attached #{channel.name} to #{selection_text(socket)}."
        {:noreply, put_flash(socket, :info, message)}
    end
  end

  def handle_event("bulk_delete", _params, socket) do
    {:ok, deleted} = Monitoring.delete_monitors(selected_ids(socket))

    {:noreply,
     socket
     |> assign(selected: MapSet.new())
     |> put_flash(:info, "#{pluralize(length(deleted), "monitor")} deleted.")}
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
     |> unmatch(monitor.id)
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
    matching = Enum.filter(monitors, &matches_filter?(&1, socket.assigns))
    matching_ids = MapSet.new(matching, & &1.id)

    rows =
      Enum.map(
        matching,
        &row(&1, display_status(&1, latest[&1.id]), Map.get(maintenance, &1.id, []))
      )

    socket
    |> assign(count: length(monitors), matching: matching_ids)
    |> update(:selected, &MapSet.intersection(&1, matching_ids))
    |> stream(:monitors, rows, reset: true)
  end

  # Whether a monitor matches the list's current filter (the search). The
  # rows, "select all" and so the bulk actions follow it, so another filter
  # (such as a label selector) only needs adding here.
  defp matches_filter?(monitor, assigns), do: matches_search?(monitor, assigns.q)

  defp upsert(socket, monitor, status) do
    if matches_filter?(monitor, socket.assigns) do
      socket
      |> update(:matching, &MapSet.put(&1, monitor.id))
      |> stream_insert(:monitors, row(monitor, status))
    else
      socket
      |> unmatch(monitor.id)
      |> stream_delete_by_dom_id(:monitors, "monitor-#{monitor.id}")
    end
  end

  # The monitor left the list, so it can't stay selected either.
  defp unmatch(socket, id) do
    socket
    |> update(:matching, &MapSet.delete(&1, id))
    |> update(:selected, &MapSet.delete(&1, id))
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

  ## Bulk actions

  defp all_selected?(%{selected: selected, matching: matching}),
    do: MapSet.size(matching) > 0 and MapSet.equal?(selected, matching)

  defp selected_ids(socket), do: MapSet.to_list(socket.assigns.selected)

  defp selection_text(socket), do: pluralize(MapSet.size(socket.assigns.selected), "monitor")

  defp pluralize(1, noun), do: "1 #{noun}"
  defp pluralize(count, noun), do: "#{count} #{noun}s"

  defp add_labels(socket, labels) do
    case Monitoring.put_labels(selected_ids(socket), labels) do
      {:ok, _changed} ->
        added = Enum.map_join(labels, ", ", &(&1 |> Labels.parse() |> elem(1) |> Labels.format()))
        {:ok, "Added #{added} to #{selection_text(socket)}."}

      {:error, changeset} ->
        {:error, bulk_error(changeset)}
    end
  end

  # Removes labels by key: `env` removes `env=prod` and `env=dev` alike.
  defp remove_labels(socket, labels) do
    with {:ok, keys} <- label_keys(labels),
         {:ok, _changed} <- Monitoring.delete_labels(selected_ids(socket), keys) do
      {:ok, "Removed #{Enum.join(keys, ", ")} from #{selection_text(socket)}."}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, bulk_error(changeset)}
      {:error, message} -> {:error, message}
    end
  end

  defp label_keys(labels) do
    Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, keys} ->
      case Labels.parse(label) do
        {:ok, {key, ""}} -> {:cont, {:ok, keys ++ [key]}}
        {:ok, _label} -> {:halt, {:error, "Remove labels by key (env, not env=prod)."}}
        {:error, message} -> {:halt, {:error, "Nothing changed: #{message}."}}
      end
    end)
  end

  # A bulk change failed and changed nothing; the changeset is the one of
  # the first monitor that could not be changed, or of the change itself.
  defp bulk_error(changeset) do
    reason =
      changeset
      |> Ecto.Changeset.traverse_errors(&translate_error/1)
      |> Enum.map_join("; ", fn {_field, messages} -> Enum.join(messages, ", ") end)

    case changeset.data do
      %{id: id, name: name} when is_integer(id) -> "Nothing changed, #{name}: #{reason}."
      _change -> "Nothing changed: #{reason}."
    end
  end

  # Suggestions for the bulk label input: the keys and labels in use.
  defp assign_label_options(socket) do
    options =
      Enum.flat_map(Monitoring.list_label_values(), fn {key, values} ->
        [key | for(value <- values, value != "", do: Labels.format({key, value}))]
      end)

    assign(socket, label_options: options)
  end
end
