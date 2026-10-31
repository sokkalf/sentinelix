defmodule SentinelixWeb.Settings.DisplaysLive do
  @moduledoc """
  Settings → Wall displays (`/settings/displays`): the user's display
  tokens (`Sentinelix.DisplayTokens`), which show some of their saved views
  on a wall or kiosk screen without a login (`/wall/<token>`,
  `SentinelixWeb.WallLive`).

  Creating a token shows its URL once; only its hash is stored, so a lost
  URL can't be shown again: revoke the token and create a new one. Editing
  changes the name, views and rotation, and open displays follow. Users
  manage only their own tokens.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents, only: [local_time: 1, format_duration: 1]

  alias Sentinelix.{DisplayTokens, SavedViews}
  alias Sentinelix.DisplayTokens.DisplayToken

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:displays}>
      <%= if @live_action in [:new, :edit] do %>
        <.header>
          {if @live_action == :new, do: "New wall display", else: "Edit wall display"}
          <:subtitle>
            Shows the views chosen full screen at its own URL, without a login. Only monitor
            names, statuses, response times and uptime are shown.
          </:subtitle>
          <:actions>
            <.button patch={~p"/settings/displays"}>Back</.button>
          </:actions>
        </.header>

        <p :if={@views == []} id="no-views" class="text-sm opacity-70">
          A display shows saved views, and you don't see any yet.
          <.link navigate={~p"/"} class="link">Save a view on the dashboard</.link>
          first.
        </p>

        <.form
          :if={@views != []}
          for={@form}
          id="display-form"
          phx-change="validate"
          phx-submit="save"
          class="max-w-xl space-y-2"
        >
          <.input
            field={@form[:name]}
            label="Name (optional)"
            placeholder="Office TV"
            maxlength="80"
          />
          <fieldset id={@form[:view_ids].id} class="fieldset mb-2">
            <legend class="label mb-1">Views</legend>
            <input type="hidden" name={@form[:view_ids].name <> "[]"} value="" />
            <label :for={view <- @views} class="label">
              <input
                type="checkbox"
                id={"display-view-#{view.slug}"}
                name={@form[:view_ids].name <> "[]"}
                value={view.id}
                checked={view.id in selected_ids(@form)}
                class="checkbox checkbox-sm"
              />
              <span>{view.name}</span>
            </label>
            <p
              :for={{message, _opts} <- @form[:view_ids].errors}
              :if={Phoenix.Component.used_input?(@form[:view_ids])}
              class="mt-1 flex items-center gap-2 text-sm text-error"
            >
              <.icon name="hero-exclamation-circle" class="size-5" />
              {message}
            </p>
            <p class="text-xs text-base-content/60">
              Shown in this order. The display shows a view only while you can see it.
            </p>
          </fieldset>
          <.input
            field={@form[:rotate_seconds]}
            type="number"
            label="Seconds per view (empty: no rotation)"
            min={DisplayToken.rotate_range().first}
            max={DisplayToken.rotate_range().last}
            placeholder="30"
          />
          <.input
            :if={@live_action == :new}
            field={@form[:expires_in_days]}
            type="select"
            label="Expires"
            options={expiry_options()}
          />
          <div class="pt-2">
            <.button variant="primary" phx-disable-with="Saving...">
              {if @live_action == :new, do: "Create display", else: "Save"}
            </.button>
          </div>
        </.form>
      <% else %>
        <.header>
          Wall displays
          <:subtitle>
            Your saved views full screen on a TV or office screen, without a login.
          </:subtitle>
          <:actions>
            <.button id="new-display" variant="primary" patch={~p"/settings/displays/new"}>
              <.icon name="hero-plus" class="size-4" /> New display
            </.button>
          </:actions>
        </.header>

        <div
          :if={@created}
          id="created-display"
          role="status"
          class="rounded-box border border-success/50 bg-success/10 p-4"
        >
          <p class="font-semibold">
            Display {if @created.name, do: "\"#{@created.name}\" "}created. Open this URL on the screen:
          </p>
          <div class="join mt-2 w-full">
            <input
              id="created-display-url"
              type="text"
              readonly
              value={@created.url}
              class="input input-sm join-item w-full font-mono"
            />
            <button
              id="copy-display-url"
              type="button"
              class="btn btn-sm join-item"
              phx-hook="CopyToClipboard"
              data-target="created-display-url"
            >
              <.icon name="hero-clipboard-document" class="size-4" /> Copy
            </button>
          </div>
          <p class="mt-2 text-sm text-base-content/70">
            This is the only time the URL is shown: it isn't stored, only a hash of it. Anyone with
            the URL sees the display, so treat it like a password. If it gets lost or leaks, revoke
            the display and create a new one.
          </p>
          <button
            type="button"
            id="dismiss-created"
            phx-click="dismiss"
            class="btn btn-ghost btn-sm mt-2"
          >
            Done
          </button>
        </div>

        <p :if={@tokens == []} id="no-displays" class="text-sm opacity-70">
          No wall displays yet.
        </p>

        <.table :if={@tokens != []} id="displays" rows={@tokens} row_id={&"display-#{&1.id}"}>
          <:col :let={token} label="Name">
            <span class="font-semibold">{token.name || "Unnamed display"}</span>
          </:col>
          <:col :let={token} label="Views">
            <span :for={tv <- token.token_views} class="mr-2 inline-block">
              <%= if SavedViews.visible?(@current_scope, tv.saved_view) do %>
                {tv.saved_view.name}
              <% else %>
                <span
                  class="line-through opacity-60"
                  title="You no longer see this view, so the display doesn't show it"
                  data-hidden-view={tv.saved_view.slug}
                >
                  {tv.saved_view.name}
                </span>
              <% end %>
            </span>
          </:col>
          <:col :let={token} label="Rotation">
            {if token.rotate_seconds, do: "every #{format_duration(token.rotate_seconds)}", else: "–"}
          </:col>
          <:col :let={token} label="Expires">
            <span :if={expired?(token)} class="badge badge-error badge-sm">Expired</span>
            <.local_time
              :if={token.expires_at && !expired?(token)}
              id={"display-#{token.id}-expires"}
              at={token.expires_at}
            />
            <span :if={!token.expires_at}>Never</span>
          </:col>
          <:col :let={token} label="Last used">
            <.local_time
              :if={token.last_used_at}
              id={"display-#{token.id}-used"}
              at={token.last_used_at}
            />
            <span :if={!token.last_used_at}>Never</span>
          </:col>
          <:action :let={token}>
            <div class="flex items-center gap-3">
              <.link
                patch={~p"/settings/displays/#{token.id}/edit"}
                id={"edit-display-#{token.id}"}
                class="link link-hover"
              >
                Edit
              </.link>
              <button
                type="button"
                id={"revoke-display-#{token.id}"}
                phx-click="revoke"
                phx-value-id={token.id}
                data-confirm={"Revoke #{token.name || "this display"}? Screens showing it disconnect."}
                class="link link-hover text-error"
              >
                Revoke
              </button>
            </div>
          </:action>
        </.table>

        <p class="text-xs text-base-content/60">
          A display shows its views as long as you can see them, and goes away if your account is
          deleted. Its URL contains the token: avoid sharing screenshots of the address bar, and
          note that reverse proxies may log URLs.
        </p>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, created: nil)}

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: "Wall displays", token: nil, form: nil)
    |> assign_tokens()
  end

  defp apply_action(socket, :new, _params) do
    scope = socket.assigns.current_scope
    token = %DisplayToken{}

    socket
    |> assign(page_title: "New wall display", token: token, created: nil)
    |> assign(views: SavedViews.list_views(scope))
    |> assign(form: to_form(DisplayTokens.change_token(scope, token)))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case DisplayTokens.get_token(scope, id) do
      nil ->
        not_found(socket)

      token ->
        socket
        |> assign(page_title: "Edit wall display", token: token, created: nil)
        |> assign(views: SavedViews.list_views(scope))
        |> assign(form: to_form(DisplayTokens.change_token(scope, token)))
    end
  end

  @impl true
  def handle_event("validate", %{"display_token" => attrs}, socket) do
    %{current_scope: scope, token: token} = socket.assigns
    form = scope |> DisplayTokens.change_token(token, attrs) |> to_form(action: :validate)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"display_token" => attrs}, socket) do
    save(socket, socket.assigns.live_action, attrs)
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %DisplayToken{} = token <- DisplayTokens.get_token(scope, id),
         {:ok, token} <- DisplayTokens.delete_token(scope, token) do
      {:noreply,
       socket
       |> put_flash(:info, "#{token.name || "Display"} revoked.")
       |> assign_tokens()}
    else
      _ -> {:noreply, not_found(socket)}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, created: nil)}

  defp save(socket, :new, attrs) do
    case DisplayTokens.create_token(socket.assigns.current_scope, attrs) do
      {:ok, token, display_token} ->
        created = %{url: url(~p"/wall/#{token}"), name: display_token.name}

        {:noreply,
         socket
         |> assign(created: created)
         |> push_patch(to: ~p"/settings/displays")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save(socket, :edit, attrs) do
    %{current_scope: scope, token: token} = socket.assigns

    case DisplayTokens.update_token(scope, token, attrs) do
      {:ok, token} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{token.name || "Display"} saved.")
         |> push_patch(to: ~p"/settings/displays")}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Keyword.has_key?(changeset.errors, :id),
          do: {:noreply, not_found(socket)},
          else: {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :forbidden} ->
        {:noreply, not_found(socket)}
    end
  end

  defp not_found(socket) do
    socket
    |> put_flash(:error, "That display doesn't exist.")
    |> push_patch(to: ~p"/settings/displays")
  end

  defp assign_tokens(socket),
    do: assign(socket, tokens: DisplayTokens.list_tokens(socket.assigns.current_scope))

  # The ids of the views checked, as the form has them (integers or the
  # strings of a submitted form).
  defp selected_ids(form) do
    (form[:view_ids].value || [])
    |> Enum.flat_map(fn
      id when is_integer(id) ->
        [id]

      id when is_binary(id) ->
        case Integer.parse(id) do
          {id, ""} -> [id]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp expiry_options do
    [{"Never", ""}] ++
      Enum.map(DisplayToken.expiry_days(), fn
        1 -> {"In 1 day", 1}
        365 -> {"In 1 year", 365}
        days -> {"In #{days} days", days}
      end)
  end

  defp expired?(%DisplayToken{expires_at: nil}), do: false

  defp expired?(%DisplayToken{expires_at: at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt
end
