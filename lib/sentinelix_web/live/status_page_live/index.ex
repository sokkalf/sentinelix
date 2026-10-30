defmodule SentinelixWeb.StatusPageLive.Index do
  @moduledoc """
  Status page management (`/status-pages`): all status pages, creating and
  deleting them. A page's groups and monitors are managed on
  `SentinelixWeb.StatusPageLive.Show`.
  """

  use SentinelixWeb, :live_view

  alias Sentinelix.StatusPages
  alias Sentinelix.StatusPages.StatusPage

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:status_pages}>
      <%= if @live_action == :new do %>
        <.header>
          New status page
          <:subtitle>A public page showing the status of selected monitors.</:subtitle>
          <:actions>
            <.button patch={~p"/status-pages"}>Back</.button>
          </:actions>
        </.header>

        <.form
          for={@form}
          id="status-page-form"
          phx-change="validate"
          phx-submit="save"
          class="max-w-2xl space-y-2"
        >
          <.input field={@form[:title]} label="Title" placeholder="Acme status" />
          <.input
            field={@form[:slug]}
            label="Slug (optional, derived from the title)"
            placeholder="acme"
          />
          <p class="-mt-1 mb-2 text-xs opacity-70">
            The page will be available at {url(~p"/status/#{@slug_preview}")}
          </p>
          <.input field={@form[:description]} type="textarea" label="Description (optional)" />
          <div class="pt-2">
            <.button variant="primary" phx-disable-with="Creating...">Create page</.button>
          </div>
        </.form>
      <% else %>
        <.header>
          Status pages
          <:subtitle>Public pages showing the status of selected monitors.</:subtitle>
          <:actions>
            <.button id="new-status-page" variant="primary" patch={~p"/status-pages/new"}>
              <.icon name="hero-plus" class="size-4" /> New status page
            </.button>
          </:actions>
        </.header>

        <p :if={@pages == []} id="no-status-pages" class="text-sm opacity-70">
          No status pages yet.
        </p>

        <.table
          :if={@pages != []}
          id="status-pages"
          rows={@pages}
          row_id={&"status-page-#{&1.page.id}"}
        >
          <:col :let={row} label="Title">
            <.link navigate={~p"/status-pages/#{row.page.id}"} class="font-semibold hover:underline">
              {row.page.title}
            </.link>
          </:col>
          <:col :let={row} label="Public URL">
            <.link
              :if={row.page.published}
              href={~p"/status/#{row.page.slug}"}
              target="_blank"
              class="link link-hover text-sm"
            >
              /status/{row.page.slug}
            </.link>
            <span :if={!row.page.published} class="text-sm opacity-70">/status/{row.page.slug}</span>
          </:col>
          <:col :let={row} label="Monitors">{row.monitor_count}</:col>
          <:col :let={row} label="Status">
            <span class={["badge badge-sm", row.page.published && "badge-success"]}>
              {if row.page.published, do: "published", else: "draft"}
            </span>
          </:col>
          <:action :let={row}>
            <.link navigate={~p"/status-pages/#{row.page.id}"} class="link link-hover">Manage</.link>
            <button
              id={"delete-status-page-#{row.page.id}"}
              phx-click="delete"
              phx-value-id={row.page.id}
              data-confirm={"Delete the status page \"#{row.page.title}\"?"}
              class="link link-hover text-error"
            >
              Delete
            </button>
          </:action>
        </.table>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  defp apply_action(socket, :index) do
    assign(socket, page_title: "Status pages", pages: StatusPages.list_status_pages(), form: nil)
  end

  defp apply_action(socket, :new) do
    socket
    |> assign(page_title: "New status page")
    |> assign_form(StatusPages.change_status_page(%StatusPage{}))
  end

  @impl true
  def handle_event("validate", %{"status_page" => params}, socket) do
    changeset = StatusPages.change_status_page(%StatusPage{}, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"status_page" => params}, socket) do
    case StatusPages.create_status_page(params) do
      {:ok, page} ->
        {:noreply,
         socket
         |> put_flash(:info, "Status page created. Add groups and monitors, then publish it.")
         |> push_navigate(to: ~p"/status-pages/#{page.id}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         %StatusPage{} = page <- StatusPages.get_status_page(id),
         {:ok, page} <- StatusPages.delete_status_page(page) do
      {:noreply,
       socket
       |> put_flash(:info, "Status page \"#{page.title}\" deleted.")
       |> assign(pages: StatusPages.list_status_pages())}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete the status page.")}
    end
  end

  defp assign_form(socket, changeset) do
    slug = Ecto.Changeset.get_field(changeset, :slug)

    assign(socket,
      form: to_form(changeset),
      slug_preview: if(slug in [nil, ""], do: "…", else: slug)
    )
  end
end
