defmodule SentinelixWeb.StatusPageLive.Show do
  @moduledoc """
  Manages a status page (`/status-pages/:id`): its groups and their
  monitors (add, remove, rename, reorder with up/down buttons), publishing,
  and its settings (`/status-pages/:id/edit`).

  A group is a fixed list or chooses its monitors by selector (see
  `Sentinelix.StatusPages.Group`). In a selector group, the monitors added
  by hand are *pinned*: shown first in their order, then the matches by
  name. While a selector is typed, the form previews exactly the monitors
  the group would show, since a selector publishes monitors that match it
  later as well.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents, only: [type_label: 1]
  import SentinelixWeb.SelectorComponents

  alias Sentinelix.{Monitoring, StatusPages}
  alias Sentinelix.StatusPages.Group

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
          No groups yet. Add a group, then pick the monitors to show in it, or choose them
          by selector.
        </p>

        <div
          :for={{group, index} <- Enum.with_index(@page.groups)}
          id={"group-#{group.id}"}
          class="rounded-box border border-base-300 bg-base-100"
        >
          <div :if={@editing == group.id} class="border-b border-base-300 p-3">
            <.group_form
              id={"group-form-#{group.id}"}
              form={@edit.form}
              preview={@edit.preview}
              suggestions={@edit.suggestions}
              page={@page}
              change="validate_group"
              submit="save_group"
            >
              <input type="hidden" name="group_id" value={group.id} />
              <:actions>
                <.button variant="primary" phx-disable-with="Saving...">Save</.button>
                <button
                  type="button"
                  id={"cancel-group-#{group.id}"}
                  phx-click="cancel_group"
                  class="btn"
                >
                  Cancel
                </button>
              </:actions>
            </.group_form>
          </div>

          <div
            :if={@editing != group.id}
            class="flex flex-wrap items-center gap-2 border-b border-base-300 p-3"
          >
            <div class="min-w-0 flex-1">
              <h2 class="truncate font-semibold">{group.name}</h2>
              <div
                :if={group.selector}
                id={"group-#{group.id}-selector"}
                class="flex items-center gap-1 text-xs opacity-70"
              >
                <.icon name="hero-funnel" class="size-3.5" />
                <code class="truncate">{group.selector}</code>
              </div>
            </div>
            <div class="flex gap-1">
              <button
                id={"edit-group-#{group.id}"}
                phx-click="edit_group"
                phx-value-id={group.id}
                class="btn btn-ghost btn-xs"
                title="Edit group"
              >
                <.icon name="hero-pencil-square" class="size-4" />
              </button>
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
            <li :if={group.monitors == []} class="px-4 py-3 text-sm opacity-70">
              {if group.selector,
                do: "No monitors match the selector.",
                else: "No monitors in this group."}
            </li>
            <.group_monitor
              :for={monitor <- group.monitors}
              group={group}
              monitor={monitor}
              pinned={pinned(group)}
            />
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
              <%= if group.selector do %>
                <.icon name="hero-bookmark" class="size-4" /> Pin monitor
              <% else %>
                <.icon name="hero-plus" class="size-4" /> Add monitor
              <% end %>
            </button>
          </form>
        </div>

        <div class="max-w-2xl rounded-box border border-dashed border-base-300 p-3">
          <.group_form
            id="new-group-form"
            form={@new.form}
            preview={@new.preview}
            suggestions={@new.suggestions}
            page={@page}
            change="validate_new_group"
            submit="create_group"
          >
            <:actions>
              <.button class="btn">
                <.icon name="hero-plus" class="size-4" /> Add group
              </.button>
            </:actions>
          </.group_form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :preview, :any, required: true, doc: "the monitors the selector shows, or nil"
  attr :suggestions, :list, required: true
  attr :page, :map, required: true
  attr :change, :string, required: true
  attr :submit, :string, required: true
  slot :inner_block
  slot :actions, required: true

  # The name and kind of a group, with the selector and its preview for
  # selector groups.
  defp group_form(assigns) do
    assigns = assign(assigns, selector?: kind(assigns.form) == :selector)

    ~H"""
    <.form for={@form} id={@id} phx-change={@change} phx-submit={@submit} class="space-y-2">
      {render_slot(@inner_block)}
      <div class="flex flex-wrap items-start gap-2">
        <div class="min-w-0 flex-1">
          <.input
            field={@form[:name]}
            id={"#{@id}-name"}
            placeholder="Group name, e.g. Websites"
            aria-label="Name"
          />
        </div>
        <div class="w-full sm:w-64">
          <.input
            field={@form[:kind]}
            id={"#{@id}-kind"}
            type="select"
            aria-label="Monitors"
            options={[
              {"Fixed list of monitors", "fixed"},
              {"Monitors matching a selector", "selector"}
            ]}
          />
        </div>
      </div>
      <div :if={@selector?}>
        <.selector_input
          id={"#{@id}-selector"}
          name={@form[:selector].name}
          value={@form[:selector].value || ""}
          error={selector_error(@form)}
          suggestions={@suggestions}
          placeholder="env=prod, service in (web,api), name~shop"
        />
        <p class="mt-1 text-xs opacity-70">
          Labels and names; not status. Monitors added to the group by hand are pinned: shown
          first, in their order, then the matches by name.
        </p>
      </div>
      <div
        :if={@selector? && @preview}
        id={"#{@id}-preview"}
        class="rounded-box border border-warning/40 bg-warning/5 p-3 text-sm"
      >
        <p class="font-medium">
          <.icon name="hero-eye" class="size-4" />
          {preview_text(@preview, @page)}
        </p>
        <p class="text-xs opacity-70">
          Monitors that match the selector later are added to the page automatically.
        </p>
        <ul :if={@preview != []} class="mt-2 flex flex-wrap gap-1">
          <li
            :for={monitor <- @preview}
            id={"#{@id}-preview-#{monitor.id}"}
            class="badge badge-sm badge-ghost"
          >
            {monitor.name}
          </li>
        </ul>
      </div>
      <div class="flex gap-2">{render_slot(@actions)}</div>
    </.form>
    """
  end

  attr :group, Group, required: true
  attr :monitor, :map, required: true
  attr :pinned, :map, required: true, doc: "the group's page monitors by monitor id"

  # A monitor of a group: the group's own monitors (pinned, in a selector
  # group) can be moved and removed, the others pinned.
  defp group_monitor(assigns) do
    assigns =
      assign(assigns,
        page_monitor: assigns.pinned[assigns.monitor.id],
        selector?: assigns.group.selector != nil
      )

    ~H"""
    <li
      id={
        if @page_monitor,
          do: "page-monitor-#{@page_monitor.id}",
          else: "matched-#{@group.id}-#{@monitor.id}"
      }
      class="flex items-center gap-2 px-4 py-2"
    >
      <div class="min-w-0 flex-1">
        <span class="truncate font-medium">{@monitor.name}</span>
        <span class="ml-2 text-xs opacity-60">{type_label(@monitor.type)}</span>
        <span :if={!@monitor.enabled} class="badge badge-ghost badge-xs ml-1">paused</span>
        <span :if={@selector? && @page_monitor} class="badge badge-xs ml-1">pinned</span>
        <span
          :if={@selector? && @page_monitor && !StatusPages.member?(@group, @monitor)}
          class="badge badge-warning badge-xs ml-1"
          title="Shown because it is pinned"
        >
          not matched
        </span>
      </div>
      <%= if @page_monitor do %>
        <.order_buttons
          event="move_monitor"
          id={@page_monitor.id}
          first?={@page_monitor.id == hd(@group.page_monitors).id}
          last?={@page_monitor.id == List.last(@group.page_monitors).id}
          dom_prefix="page-monitor"
        />
        <button
          id={"remove-page-monitor-#{@page_monitor.id}"}
          phx-click="remove_monitor"
          phx-value-id={@page_monitor.id}
          class="btn btn-ghost btn-xs text-error"
          title={if @selector?, do: "Unpin", else: "Remove from group"}
        >
          <.icon name={if @selector?, do: "hero-bookmark-slash", else: "hero-x-mark"} class="size-4" />
        </button>
      <% else %>
        <button
          id={"pin-#{@group.id}-#{@monitor.id}"}
          phx-click="add_monitor"
          phx-value-group_id={@group.id}
          phx-value-monitor_id={@monitor.id}
          class="btn btn-ghost btn-xs"
          title="Pin (show before the other matches)"
        >
          <.icon name="hero-bookmark" class="size-4" />
        </button>
      <% end %>
    </li>
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
         |> assign(page: page, monitors: Monitoring.list_monitors(), editing: nil, edit: nil)
         |> assign_completion()
         |> assign_new_group_form()}
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

  def handle_event("validate_new_group", %{"group" => params}, socket) do
    changeset = %Group{} |> StatusPages.change_group(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, new: group_form_state(socket, %Group{}, changeset, params))}
  end

  def handle_event("create_group", %{"group" => params}, socket) do
    case StatusPages.create_group(socket.assigns.page, params) do
      {:ok, _group} ->
        {:noreply, socket |> reload() |> assign_new_group_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, new: group_form_state(socket, %Group{}, changeset, params))}
    end
  end

  def handle_event("edit_group", %{"id" => id}, socket) do
    with_group(socket, id, fn _group ->
      group = loaded_group(socket, parse_id(id))
      changeset = StatusPages.change_group(group)

      assign(socket,
        editing: group.id,
        edit: group_form_state(socket, group, changeset, %{"selector" => group.selector})
      )
    end)
  end

  def handle_event("cancel_group", _params, socket) do
    {:noreply, assign(socket, editing: nil, edit: nil)}
  end

  def handle_event("validate_group", %{"group_id" => id, "group" => params}, socket) do
    with_group(socket, id, fn _group ->
      group = loaded_group(socket, parse_id(id))
      changeset = group |> StatusPages.change_group(params) |> Map.put(:action, :validate)
      assign(socket, edit: group_form_state(socket, group, changeset, params))
    end)
  end

  def handle_event("save_group", %{"group_id" => id, "group" => params}, socket) do
    with_group(socket, id, fn group ->
      case StatusPages.update_group(group, params) do
        {:ok, _group} ->
          socket
          |> put_flash(:info, "Group saved.")
          |> assign(editing: nil, edit: nil)
          |> reload()

        {:error, changeset} ->
          group = loaded_group(socket, group.id)
          assign(socket, edit: group_form_state(socket, group, changeset, params))
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

  # Adds a monitor to a fixed list, or pins it in a selector group.
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

  # The group as loaded with the page (its pinned monitors preloaded), or
  # a fresh copy when the page doesn't have it yet.
  defp loaded_group(socket, id) do
    Enum.find(socket.assigns.page.groups, &(&1.id == id)) ||
      Enum.find(StatusPages.get_status_page!(socket.assigns.page.id).groups, &(&1.id == id))
  end

  defp reload(socket) do
    socket
    |> assign(
      page: StatusPages.get_status_page!(socket.assigns.page.id),
      monitors: Monitoring.list_monitors()
    )
    |> assign_completion()
  end

  ## Group forms

  defp assign_new_group_form(socket) do
    changeset = StatusPages.change_group(%Group{})
    assign(socket, new: group_form_state(socket, %Group{}, changeset, %{}))
  end

  # Selector completion: label keys and values in use, and names; no
  # status, which groups don't allow.
  defp assign_completion(socket) do
    values =
      socket.assigns.monitors
      |> label_values()
      |> completion_values()
      |> Map.delete("status")

    assign(socket, completion: values)
  end

  # The form of a group, the monitors it would show (for a valid selector)
  # and the completions of the selector typed so far.
  defp group_form_state(socket, group, changeset, params) do
    text = params["selector"] || ""

    %{
      form: to_form(changeset),
      preview: preview(socket, group, changeset),
      suggestions: if(text == "", do: [], else: suggestions(text, socket.assigns.completion))
    }
  end

  defp preview(socket, group, changeset) do
    selector = Ecto.Changeset.get_field(changeset, :selector)

    if Ecto.Changeset.get_field(changeset, :kind) == :selector and is_binary(selector) and
         not Keyword.has_key?(changeset.errors, :selector) do
      group = %{group | selector: selector, page_monitors: loaded_page_monitors(group)}
      StatusPages.group_monitors(group, socket.assigns.monitors)
    end
  end

  defp loaded_page_monitors(%Group{page_monitors: page_monitors}) when is_list(page_monitors),
    do: page_monitors

  defp loaded_page_monitors(%Group{}), do: []

  defp kind(form) do
    case form[:kind].value do
      kind when kind in [:selector, "selector"] -> :selector
      _fixed -> :fixed
    end
  end

  defp selector_error(form) do
    case form[:selector].errors do
      [error | _rest] -> translate_error(error)
      [] -> nil
    end
  end

  defp preview_text([], _page), do: "Matches no monitors yet."

  defp preview_text(monitors, page) do
    count = length(monitors)
    noun = if count == 1, do: "monitor", else: "monitors"
    "Shows #{count} #{noun}#{preview_suffix(page)}:"
  end

  defp preview_suffix(%{published: true, show_details: true}),
    do: " publicly, with their names, statuses and targets"

  defp preview_suffix(%{published: true}), do: " publicly, with their names and statuses"
  defp preview_suffix(_draft), do: " on the page once it is published"

  defp pinned(group), do: Map.new(group.page_monitors, &{&1.monitor_id, &1})

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
