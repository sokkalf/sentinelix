defmodule SentinelixWeb.StatusPageLive.Show do
  @moduledoc """
  Manages a status page (`/status-pages/:id`): its groups and their
  monitors (add, remove, rename, reorder with up/down buttons), publishing,
  and its settings (`/status-pages/:id/edit`).
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents, only: [type_label: 1]

  alias Sentinelix.{Monitoring, StatusPages}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:status_pages}>
      <.header>
        {@page.title}
        <:subtitle>
          <span class={["badge badge-sm mr-1", @page.published && "badge-success"]}>
            {if @page.published, do: "published", else: "draft"}
          </span>
          {url(~p"/status/#{@page.slug}")}
        </:subtitle>
        <:actions>
          <.link
            :if={@page.published}
            id="view-public-page"
            href={~p"/status/#{@page.slug}"}
            target="_blank"
            class="btn"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" /> View
          </.link>
          <.button id="toggle-published" phx-click="toggle_published">
            {if @page.published, do: "Unpublish", else: "Publish"}
          </.button>
          <.button
            :if={@live_action == :show}
            id="edit-settings"
            patch={~p"/status-pages/#{@page.id}/edit"}
          >
            <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
          </.button>
          <.button :if={@live_action == :edit} patch={~p"/status-pages/#{@page.id}"}>Back</.button>
        </:actions>
      </.header>

      <.form
        :if={@live_action == :edit}
        for={@form}
        id="status-page-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-2xl space-y-2"
      >
        <.input field={@form[:title]} label="Title" />
        <.input field={@form[:slug]} label="Slug" />
        <.input field={@form[:description]} type="textarea" label="Description (optional)" />
        <.input field={@form[:footer_text]} type="textarea" label="Footer text (optional)" />
        <.input field={@form[:published]} type="checkbox" label="Published (publicly visible)" />
        <.input
          field={@form[:show_details]}
          type="checkbox"
          label="Show technical details: monitor targets (URLs, hosts) and check and incident messages"
        />
        <div class="pt-2">
          <.button variant="primary" phx-disable-with="Saving...">Save</.button>
        </div>
      </.form>

      <div :if={@live_action == :show} class="space-y-4">
        <p :if={@page.groups == []} id="no-groups" class="text-sm opacity-70">
          No groups yet. Add a group, then pick the monitors to show in it.
        </p>

        <div
          :for={{group, index} <- Enum.with_index(@page.groups)}
          id={"group-#{group.id}"}
          class="rounded-box border border-base-300 bg-base-100"
        >
          <div class="flex flex-wrap items-center gap-2 border-b border-base-300 p-3">
            <form
              id={"rename-group-#{group.id}"}
              phx-submit="rename_group"
              class="flex min-w-0 flex-1 items-center gap-2"
            >
              <input type="hidden" name="group_id" value={group.id} />
              <input
                type="text"
                name="name"
                value={group.name}
                class="input input-sm min-w-0 flex-1 font-semibold sm:max-w-xs"
                aria-label="Group name"
                required
              />
              <button class="btn btn-ghost btn-sm">Rename</button>
            </form>
            <div class="flex gap-1">
              <.order_buttons
                event="move_group"
                id={group.id}
                first?={index == 0}
                last?={index == length(@page.groups) - 1}
                dom_prefix="group"
              />
              <button
                id={"delete-group-#{group.id}"}
                phx-click="delete_group"
                phx-value-id={group.id}
                data-confirm={"Delete the group \"#{group.name}\"?"}
                class="btn btn-ghost btn-xs text-error"
                title="Delete group"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>

          <ul class="divide-y divide-base-300">
            <li :if={group.page_monitors == []} class="px-4 py-3 text-sm opacity-70">
              No monitors in this group.
            </li>
            <li
              :for={{pm, pm_index} <- Enum.with_index(group.page_monitors)}
              id={"page-monitor-#{pm.id}"}
              class="flex items-center gap-2 px-4 py-2"
            >
              <div class="min-w-0 flex-1">
                <span class="truncate font-medium">{pm.monitor.name}</span>
                <span class="ml-2 text-xs opacity-60">{type_label(pm.monitor.type)}</span>
                <span :if={!pm.monitor.enabled} class="badge badge-ghost badge-xs ml-1">paused</span>
              </div>
              <.order_buttons
                event="move_monitor"
                id={pm.id}
                first?={pm_index == 0}
                last?={pm_index == length(group.page_monitors) - 1}
                dom_prefix="page-monitor"
              />
              <button
                id={"remove-page-monitor-#{pm.id}"}
                phx-click="remove_monitor"
                phx-value-id={pm.id}
                class="btn btn-ghost btn-xs text-error"
                title="Remove from group"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </li>
          </ul>

          <form
            :if={available_monitors(@monitors, group) != []}
            id={"add-monitor-#{group.id}"}
            phx-submit="add_monitor"
            class="flex items-center gap-2 border-t border-base-300 p-3"
          >
            <input type="hidden" name="group_id" value={group.id} />
            <select
              name="monitor_id"
              class="select select-sm min-w-0 flex-1 sm:max-w-xs"
              aria-label="Monitor"
            >
              {Phoenix.HTML.Form.options_for_select(
                Enum.map(available_monitors(@monitors, group), &{&1.name, &1.id}),
                nil
              )}
            </select>
            <button class="btn btn-sm">
              <.icon name="hero-plus" class="size-4" /> Add monitor
            </button>
          </form>
        </div>

        <.form
          for={@group_form}
          id="new-group-form"
          phx-submit="create_group"
          class="flex max-w-md items-start gap-2"
        >
          <div class="flex-1">
            <.input field={@group_form[:name]} placeholder="New group, e.g. Websites" />
          </div>
          <.button class="btn mt-1">
            <.icon name="hero-plus" class="size-4" /> Add group
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  attr :event, :string, required: true
  attr :id, :integer, required: true
  attr :first?, :boolean, required: true
  attr :last?, :boolean, required: true
  attr :dom_prefix, :string, required: true

  defp order_buttons(assigns) do
    ~H"""
    <button
      id={"#{@dom_prefix}-#{@id}-up"}
      phx-click={@event}
      phx-value-id={@id}
      phx-value-direction="up"
      class="btn btn-ghost btn-xs"
      title="Move up"
      disabled={@first?}
    >
      <.icon name="hero-arrow-up" class="size-4" />
    </button>
    <button
      id={"#{@dom_prefix}-#{@id}-down"}
      phx-click={@event}
      phx-value-id={@id}
      phx-value-direction="down"
      class="btn btn-ghost btn-xs"
      title="Move down"
      disabled={@last?}
    >
      <.icon name="hero-arrow-down" class="size-4" />
    </button>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case parse_id(id) && StatusPages.get_status_page(parse_id(id)) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Status page not found.")
         |> push_navigate(to: ~p"/status-pages")}

      page ->
        {:ok,
         socket
         |> assign(page: page, monitors: Monitoring.list_monitors())
         |> assign_group_form()}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  defp apply_action(socket, :show) do
    assign(socket, page_title: socket.assigns.page.title, form: nil)
  end

  defp apply_action(socket, :edit) do
    socket
    |> assign(page_title: "Edit #{socket.assigns.page.title}")
    |> assign(form: to_form(StatusPages.change_status_page(socket.assigns.page)))
  end

  @impl true
  def handle_event("validate", %{"status_page" => params}, socket) do
    changeset =
      socket.assigns.page
      |> StatusPages.change_status_page(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"status_page" => params}, socket) do
    case StatusPages.update_status_page(socket.assigns.page, params) do
      {:ok, _page} ->
        {:noreply,
         socket
         |> put_flash(:info, "Status page saved.")
         |> reload()
         |> push_patch(to: ~p"/status-pages/#{socket.assigns.page.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("toggle_published", _params, socket) do
    page = socket.assigns.page

    case StatusPages.update_status_page(page, %{published: !page.published}) do
      {:ok, page} ->
        message =
          if page.published, do: "Status page published.", else: "Status page unpublished."

        {:noreply, socket |> put_flash(:info, message) |> reload()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update the status page.")}
    end
  end

  def handle_event("create_group", %{"group" => params}, socket) do
    case StatusPages.create_group(socket.assigns.page, params) do
      {:ok, _group} -> {:noreply, socket |> reload() |> assign_group_form()}
      {:error, changeset} -> {:noreply, assign(socket, group_form: to_form(changeset))}
    end
  end

  def handle_event("rename_group", %{"group_id" => id, "name" => name}, socket) do
    with_group(socket, id, fn group ->
      case StatusPages.update_group(group, %{name: name}) do
        {:ok, _group} -> socket |> put_flash(:info, "Group renamed.") |> reload()
        {:error, _changeset} -> put_flash(socket, :error, "The group name can't be blank.")
      end
    end)
  end

  def handle_event("move_group", %{"id" => id, "direction" => direction}, socket) do
    with_group(socket, id, fn group ->
      :ok = StatusPages.move_group(group, parse_direction(direction))
      reload(socket)
    end)
  end

  def handle_event("delete_group", %{"id" => id}, socket) do
    with_group(socket, id, fn group ->
      {:ok, _group} = StatusPages.delete_group(group)
      reload(socket)
    end)
  end

  def handle_event("add_monitor", %{"group_id" => group_id, "monitor_id" => monitor_id}, socket) do
    with_group(socket, group_id, fn group ->
      with id when is_integer(id) <- parse_id(monitor_id),
           {:ok, _page_monitor} <- StatusPages.add_monitor(group, id) do
        reload(socket)
      else
        _ -> put_flash(socket, :error, "Could not add the monitor.")
      end
    end)
  end

  def handle_event("move_monitor", %{"id" => id, "direction" => direction}, socket) do
    with_page_monitor(socket, id, fn page_monitor ->
      :ok = StatusPages.move_monitor(page_monitor, parse_direction(direction))
      reload(socket)
    end)
  end

  def handle_event("remove_monitor", %{"id" => id}, socket) do
    with_page_monitor(socket, id, fn page_monitor ->
      {:ok, _page_monitor} = StatusPages.remove_monitor(page_monitor)
      reload(socket)
    end)
  end

  defp with_group(socket, id, fun) do
    case parse_id(id) && StatusPages.get_group(socket.assigns.page, parse_id(id)) do
      nil -> {:noreply, socket |> put_flash(:error, "Group not found.") |> reload()}
      group -> {:noreply, fun.(group)}
    end
  end

  defp with_page_monitor(socket, id, fun) do
    case parse_id(id) && StatusPages.get_page_monitor(socket.assigns.page, parse_id(id)) do
      nil -> {:noreply, socket |> put_flash(:error, "Monitor not found.") |> reload()}
      page_monitor -> {:noreply, fun.(page_monitor)}
    end
  end

  defp reload(socket) do
    assign(socket,
      page: StatusPages.get_status_page!(socket.assigns.page.id),
      monitors: Monitoring.list_monitors()
    )
  end

  defp assign_group_form(socket) do
    assign(socket, group_form: to_form(StatusPages.change_group(%StatusPages.Group{})))
  end

  defp available_monitors(monitors, group) do
    taken = MapSet.new(group.page_monitors, & &1.monitor_id)
    Enum.reject(monitors, &MapSet.member?(taken, &1.id))
  end

  defp parse_direction("up"), do: :up
  defp parse_direction(_down), do: :down

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> id
      _ -> nil
    end
  end
end
