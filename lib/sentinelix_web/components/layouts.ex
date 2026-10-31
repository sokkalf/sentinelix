defmodule SentinelixWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SentinelixWeb, :html

  alias Sentinelix.Accounts.User
  alias SentinelixWeb.SavedViewsNav

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout.

  Logged in users get the app shell: a sidebar with the navigation (a drawer
  on small screens) and the user's saved views under the dashboard (see
  `SentinelixWeb.SavedViewsNav`, so only render it in LiveViews), a top bar
  with the theme toggle and the user menu.
  Without a user (login pages) a minimal centered layout is rendered.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} active={:dashboard}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :any,
    default: nil,
    doc: "the key of the active navigation item, `{:view, slug}` for a saved view"

  slot :inner_block, required: true

  def app(%{current_scope: %{user: %{}}} = assigns) do
    assigns = assign(assigns, :nav, nav_sections())

    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="app-drawer" type="checkbox" class="drawer-toggle" />
      <div class="drawer-content flex min-h-screen flex-col">
        <header class="navbar sticky top-0 z-30 gap-2 border-b border-base-300 bg-base-100/90 px-4 backdrop-blur sm:px-6">
          <div class="flex-none lg:hidden">
            <label for="app-drawer" class="btn btn-square btn-ghost btn-sm" aria-label="Open menu">
              <.icon name="hero-bars-3" class="size-5" />
            </label>
          </div>
          <div class="flex-1">
            <.link navigate={~p"/"} class="flex w-fit items-center gap-2 lg:hidden">
              <.logo />
            </.link>
          </div>
          <div class="flex flex-none items-center gap-2">
            <.theme_toggle />
            <.user_menu user={@current_scope.user} />
          </div>
        </header>

        <main class="flex-1 px-4 py-6 sm:px-6 lg:px-8">
          <div class="mx-auto max-w-7xl space-y-6">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <div class="drawer-side z-40">
        <label for="app-drawer" aria-label="Close menu" class="drawer-overlay"></label>
        <aside class="flex min-h-full w-64 flex-col border-r border-base-300 bg-base-200">
          <.link navigate={~p"/"} class="flex h-16 items-center gap-2 px-6">
            <.logo />
          </.link>
          <nav id="app-nav" class="flex-1 px-3 py-2">
            <ul :for={{title, items} <- @nav} class="menu w-full gap-0.5 p-0 pb-4">
              <li :if={title} class="menu-title px-3 pt-2 text-xs uppercase tracking-wide">
                {title}
              </li>
              <li :for={item <- items}>
                <.link
                  navigate={item.path}
                  class={[item.key == @active && "menu-active"]}
                  aria-current={item.key == @active && "page"}
                >
                  <.icon name={item.icon} class="size-5" /> {item.label}
                </.link>
                <.live_component
                  :if={item.key == :dashboard}
                  module={SavedViewsNav}
                  id={SavedViewsNav.id()}
                  scope={@current_scope}
                  active={@active}
                />
              </li>
            </ul>
          </nav>
          <div class="px-6 py-4 text-xs opacity-50">
            Sentinelix {Sentinelix.version()}
          </div>
        </aside>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  def app(assigns) do
    ~H"""
    <header class="navbar border-b border-base-300 px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <.link navigate={~p"/"} class="flex w-fit items-center gap-2">
          <.logo />
        </.link>
      </div>
      <div class="flex flex-none items-center gap-4">
        <.theme_toggle />
      </div>
    </header>

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-full space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders the minimal layout of public pages (status pages): no navigation
  and no user information, just a title bar with the theme toggle, the
  content and a footer.

  ## Examples

      <Layouts.public flash={@flash} title="Acme status">
        <h1>Content</h1>
        <:footer>Questions? support@example.com</:footer>
      </Layouts.public>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :title, :string, required: true
  slot :inner_block, required: true
  slot :footer

  def public(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col bg-base-200/40">
      <header class="border-b border-base-300 bg-base-100">
        <div class="mx-auto flex max-w-4xl items-center gap-4 px-4 py-4 sm:px-6">
          <h1 id="page-title" class="min-w-0 flex-1 truncate text-xl font-semibold tracking-tight">
            {@title}
          </h1>
          <.theme_toggle />
        </div>
      </header>

      <main class="flex-1 px-4 py-8 sm:px-6">
        <div class="mx-auto max-w-4xl space-y-8">
          {render_slot(@inner_block)}
        </div>
      </main>

      <footer class="border-t border-base-300 bg-base-100">
        <div class="mx-auto max-w-4xl space-y-1 px-4 py-6 text-center text-sm text-base-content/60 sm:px-6">
          <div :if={@footer != []} id="page-footer" class="whitespace-pre-line">
            {render_slot(@footer)}
          </div>
          <div class="text-xs">Powered by Sentinelix</div>
        </div>
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  # The sidebar navigation: a list of `{section_title, items}`. Later
  # features add their entries here (status pages, maintenance windows,
  # notification settings, ...); only link to routes that exist.
  defp nav_sections do
    [
      {nil,
       [
         %{key: :dashboard, label: "Dashboard", icon: "hero-squares-2x2", path: ~p"/"},
         %{key: :monitors, label: "Monitors", icon: "hero-signal", path: ~p"/monitors"},
         %{
           key: :status_pages,
           label: "Status pages",
           icon: "hero-globe-alt",
           path: ~p"/status-pages"
         },
         %{
           key: :maintenance,
           label: "Maintenance",
           icon: "hero-wrench-screwdriver",
           path: ~p"/maintenance"
         }
       ]},
      {"Settings",
       [
         %{
           key: :notifications,
           label: "Notifications",
           icon: "hero-bell",
           path: ~p"/settings/notifications"
         },
         %{
           key: :displays,
           label: "Wall displays",
           icon: "hero-tv",
           path: ~p"/settings/displays"
         },
         %{
           key: :users,
           label: "Users & sessions",
           icon: "hero-users",
           path: ~p"/settings/users"
         }
       ]}
    ]
  end

  defp logo(assigns) do
    ~H"""
    <span class="grid size-8 place-items-center rounded-lg bg-primary text-primary-content">
      <.icon name="hero-signal" class="size-5" />
    </span>
    <span class="text-lg font-semibold tracking-tight">Sentinelix</span>
    """
  end

  attr :user, :map, required: true

  defp user_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <div
        tabindex="0"
        role="button"
        class="btn btn-ghost btn-sm gap-2 px-2"
        aria-label="User menu"
      >
        <span class="grid size-7 place-items-center rounded-full bg-neutral text-xs font-semibold text-neutral-content">
          {initials(@user)}
        </span>
        <span id="current-user" class="hidden max-w-40 truncate text-sm font-normal sm:inline">
          {User.display_name(@user)}
        </span>
        <.icon name="hero-chevron-down-micro" class="size-4 opacity-60" />
      </div>
      <ul
        tabindex="0"
        class="menu dropdown-content z-50 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
      >
        <li class="menu-title">
          <span class="truncate">{@user.email || User.display_name(@user)}</span>
        </li>
        <li>
          <.link navigate={~p"/settings/users"}>
            <.icon name="hero-users" class="size-4" /> Users & sessions
          </.link>
        </li>
        <li>
          <.link href={~p"/admin/dashboard"}>
            <.icon name="hero-cpu-chip" class="size-4" /> System dashboard
          </.link>
        </li>
        <li>
          <.link href={~p"/logout"} method="delete" id="logout-link">
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Log out
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp initials(user) do
    user
    |> User.display_name()
    |> String.split(~r/[\s@._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
