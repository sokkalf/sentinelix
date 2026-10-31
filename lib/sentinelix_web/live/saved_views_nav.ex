defmodule SentinelixWeb.SavedViewsNav do
  @moduledoc """
  The saved views in the sidebar, under the dashboard: the views the
  current user sees (`Sentinelix.SavedViews.list_views/1`), in their order,
  and a link to manage them.

  A live component rendered by `SentinelixWeb.Layouts.app/1` (with the id
  `id/0`), so the views are loaded once per LiveView, not on every render.
  It's also an `on_mount` hook for the app's `live_session`: connected
  LiveViews subscribe to saved view changes and the hook reloads the list
  when one comes (the event doesn't reach the LiveView itself).
  """

  use SentinelixWeb, :live_component

  import SentinelixWeb.SavedViewComponents

  alias Sentinelix.SavedViews

  @id "saved-views-nav"

  @doc "The DOM and component id of the list."
  @spec id() :: String.t()
  def id, do: @id

  @doc false
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) and socket.assigns[:current_scope], do: SavedViews.subscribe()

    {:cont, attach_hook(socket, :saved_views_nav, :handle_info, &handle_change/2)}
  end

  defp handle_change({:saved_views_changed}, socket) do
    send_update(__MODULE__, id: @id, reload: true)
    {:halt, socket}
  end

  defp handle_change(_message, socket), do: {:cont, socket}

  @impl true
  def update(%{reload: true}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    reload? = socket.assigns[:scope] != assigns.scope

    socket = assign(socket, scope: assigns.scope, active: assigns.active)
    {:ok, if(reload?, do: load(socket), else: socket)}
  end

  defp load(socket) do
    scope = socket.assigns.scope
    assign(socket, views: SavedViews.list_views(scope), default_id: scope.user.default_view_id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ul id={id()} class={[@views == [] && "hidden"]}>
      <li :for={view <- @views} id={"nav-view-#{view.slug}"}>
        <.link
          navigate={~p"/views/#{view.slug}"}
          class={["py-1", @active == {:view, view.slug} && "menu-active"]}
          aria-current={@active == {:view, view.slug} && "page"}
          title={"#{visibility_label(view)} · by #{owner_name(view, @scope)}"}
        >
          <.icon name={visibility_icon(view)} class="size-4 opacity-60" />
          <span class="truncate">{view.name}</span>
          <span :if={view.id == @default_id} data-role="default" title="Your default view">
            <.icon name="hero-star-solid" class="size-3 opacity-60" />
          </span>
        </.link>
      </li>
      <li>
        <.link
          navigate={~p"/views"}
          id="nav-manage-views"
          class={["py-1 text-xs opacity-70", @active == :saved_views && "menu-active"]}
        >
          <.icon name="hero-adjustments-horizontal" class="size-4" /> Manage views
        </.link>
      </li>
    </ul>
    """
  end
end
