defmodule SentinelixWeb.SavedViewLive.Index do
  @moduledoc """
  The saved views page (`/views`): the views the user sees (their own and
  the ones others share with them), picking the default view for `/`, and,
  for the user's own views, renaming them and changing who sees them
  (`/views/<slug>/edit`), reordering and deleting them.

  Views are saved and their filters changed on the dashboard
  (`SentinelixWeb.DashboardLive`). Only the owner of a view changes it; the
  `Sentinelix.SavedViews` context checks that for every event.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.SavedViewComponents

  alias Sentinelix.SavedViews
  alias Sentinelix.SavedViews.SavedView

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:saved_views}>
      <%= if @live_action == :edit do %>
        <.header>
          Edit view
          <:subtitle>
            Shown at <.link navigate={~p"/views/#{@view.slug}"} class="link">/views/{@view.slug}</.link>.
            Change its filters on the dashboard and use "Update view".
          </:subtitle>
          <:actions>
            <.button patch={~p"/views"}>Back</.button>
          </:actions>
        </.header>

        <.form
          for={@form}
          id="saved-view-form"
          phx-change="validate"
          phx-submit="save"
          class="max-w-xl space-y-2"
        >
          <.saved_view_fields form={@form} groups={@current_scope.groups} />
          <div class="pt-2">
            <.button variant="primary" phx-disable-with="Saving...">Save</.button>
          </div>
        </.form>
      <% else %>
        <.header>
          Saved views
          <:subtitle>
            Your views and the views others share with you. Only a view's owner can change it.
          </:subtitle>
          <:actions>
            <.button navigate={~p"/"}>
              <.icon name="hero-bookmark" class="size-4" /> Save a view on the dashboard
            </.button>
          </:actions>
        </.header>

        <p :if={@views == []} id="no-saved-views" class="text-sm opacity-70">
          No saved views yet. Filter or group the dashboard and use "Save view".
        </p>

        <.table :if={@views != []} id="saved-views" rows={@views} row_id={&"saved-view-#{&1.slug}"}>
          <:col :let={view} label="Name">
            <.link navigate={~p"/views/#{view.slug}"} class="font-semibold hover:underline">
              {view.name}
            </.link>
          </:col>
          <:col :let={view} label="Visible to"><.visibility_badge view={view} /></:col>
          <:col :let={view} label="Owner">{owner_name(view, @current_scope)}</:col>
          <:col :let={view} label="Default">
            <button
              type="button"
              id={"default-#{view.slug}"}
              phx-click="toggle_default"
              phx-value-slug={view.slug}
              class="btn btn-ghost btn-xs"
              aria-pressed={to_string(view.id == @current_scope.user.default_view_id)}
              title={
                if view.id == @current_scope.user.default_view_id,
                  do: "Your default view (shown at /). Click to unset.",
                  else: "Show this view at /"
              }
            >
              <.icon
                name={
                  if view.id == @current_scope.user.default_view_id,
                    do: "hero-star-solid",
                    else: "hero-star"
                }
                class="size-4"
              />
            </button>
          </:col>
          <:action :let={view}>
            <div :if={SavedViews.owner?(@current_scope, view)} class="flex items-center gap-3">
              <button
                type="button"
                id={"move-up-#{view.slug}"}
                phx-click="move"
                phx-value-slug={view.slug}
                phx-value-direction="up"
                class="link link-hover"
                aria-label={"Move #{view.name} up"}
              >
                <.icon name="hero-arrow-up-mini" class="size-4" />
              </button>
              <button
                type="button"
                id={"move-down-#{view.slug}"}
                phx-click="move"
                phx-value-slug={view.slug}
                phx-value-direction="down"
                class="link link-hover"
                aria-label={"Move #{view.name} down"}
              >
                <.icon name="hero-arrow-down-mini" class="size-4" />
              </button>
              <.link
                patch={~p"/views/#{view.slug}/edit"}
                id={"edit-#{view.slug}"}
                class="link link-hover"
              >
                Edit
              </.link>
              <button
                type="button"
                id={"delete-#{view.slug}"}
                phx-click="delete"
                phx-value-slug={view.slug}
                data-confirm={"Delete the view \"#{view.name}\"?"}
                class="link link-hover text-error"
              >
                Delete
              </button>
            </div>
          </:action>
        </.table>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: "Saved views", view: nil, form: nil)
    |> assign_views()
  end

  defp apply_action(socket, :edit, %{"slug" => slug}) do
    scope = socket.assigns.current_scope

    case SavedViews.get_view(scope, slug) do
      %SavedView{} = view ->
        if SavedViews.owner?(scope, view) do
          assign(socket,
            page_title: "Edit view",
            view: view,
            form: to_form(SavedViews.change_view(scope, view))
          )
        else
          socket
          |> put_flash(:error, "Only the owner of a view can change it.")
          |> push_patch(to: ~p"/views")
        end

      nil ->
        not_found(socket)
    end
  end

  @impl true
  def handle_event("validate", %{"saved_view" => attrs}, socket) do
    %{current_scope: scope, view: view} = socket.assigns
    form = scope |> SavedViews.change_view(view, attrs) |> to_form(action: :validate)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"saved_view" => attrs}, socket) do
    %{current_scope: scope, view: view} = socket.assigns

    case SavedViews.update_view(scope, view, attrs) do
      {:ok, view} ->
        {:noreply,
         socket
         |> put_flash(:info, "View \"#{view.name}\" saved.")
         |> push_patch(to: ~p"/views")}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Keyword.has_key?(changeset.errors, :id),
          do: {:noreply, not_found(socket)},
          else: {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :forbidden} ->
        {:noreply, forbidden(socket)}
    end
  end

  def handle_event("move", %{"slug" => slug, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    with_view(socket, slug, fn view ->
      SavedViews.move_view(socket.assigns.current_scope, view, String.to_existing_atom(direction))
    end)
  end

  def handle_event("delete", %{"slug" => slug}, socket) do
    with_view(socket, slug, fn view ->
      with {:ok, view} <- SavedViews.delete_view(socket.assigns.current_scope, view) do
        {:ok, "View \"#{view.name}\" deleted."}
      end
    end)
  end

  def handle_event("toggle_default", %{"slug" => slug}, socket) do
    scope = socket.assigns.current_scope

    with_view(socket, slug, fn view ->
      default = if view.id == scope.user.default_view_id, do: nil, else: view

      with {:ok, user} <- SavedViews.set_default_view(scope, default) do
        {:ok, {:scope, %{scope | user: user}}}
      end
    end)
  end

  # Runs `fun` with a view the user sees, reporting what goes wrong.
  defp with_view(socket, slug, fun) do
    case SavedViews.get_view(socket.assigns.current_scope, slug) do
      nil ->
        {:noreply, not_found(socket)}

      view ->
        case fun.(view) do
          {:ok, {:scope, scope}} ->
            {:noreply, socket |> assign(current_scope: scope) |> assign_views()}

          {:ok, message} when is_binary(message) ->
            {:noreply, socket |> put_flash(:info, message) |> assign_views()}

          {:ok, _result} ->
            {:noreply, assign_views(socket)}

          {:error, :forbidden} ->
            {:noreply, forbidden(socket)}

          {:error, _reason} ->
            {:noreply, not_found(socket)}
        end
    end
  end

  defp not_found(socket) do
    socket
    |> put_flash(:error, "That view doesn't exist or isn't shared with you.")
    |> push_patch(to: ~p"/views")
  end

  defp forbidden(socket),
    do: socket |> put_flash(:error, "Only the owner of a view can change it.") |> assign_views()

  defp assign_views(socket),
    do: assign(socket, views: SavedViews.list_views(socket.assigns.current_scope))
end
