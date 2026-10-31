defmodule SentinelixWeb.Router do
  use SentinelixWeb, :router

  import SentinelixWeb.UserAuth
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SentinelixWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Wall displays: no user session; the display token in the path is the
  # credential (SentinelixWeb.WallAuth). The session is only fetched for
  # LiveView's CSRF token. No referrer, so the token isn't sent on.
  pipeline :wall do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {SentinelixWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"referrer-policy" => "no-referrer"}
    plug SentinelixWeb.WallAuth
  end

  ## Public routes – NO authentication.
  #
  # Keep everything here free of auth plugs and hooks.

  scope "/", SentinelixWeb do
    pipe_through :browser

    # Public status pages (#10): only published pages, see StatusPageLive.Public.
    live_session :public do
      live "/status/:slug", StatusPageLive.Public
    end
  end

  # Wall/kiosk displays (#44): the saved views of a display token, see
  # SentinelixWeb.WallAuth and SentinelixWeb.WallLive.
  scope "/", SentinelixWeb do
    pipe_through :wall

    live_session :wall, on_mount: [SentinelixWeb.WallAuth] do
      live "/wall/:token", WallLive
    end
  end

  # Push/heartbeat endpoint for push monitors (#6); the token is the credential.
  scope "/api", SentinelixWeb do
    pipe_through :api

    get "/push/:token", PushController, :push
    post "/push/:token", PushController, :push
  end

  # Health check and Prometheus metrics: no pipeline at all (no session,
  # CSRF or content negotiation). /metrics checks its own bearer token
  # (METRICS_TOKEN), see SentinelixWeb.MetricsController.
  scope "/", SentinelixWeb do
    get "/healthz", HealthController, :show
    get "/metrics", MetricsController, :show
  end

  ## Authentication routes (login page, OIDC redirect + callback)

  scope "/", SentinelixWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/auth/oidc", OIDCController, :request
    get "/auth/oidc/callback", OIDCController, :callback
  end

  scope "/", SentinelixWeb do
    pipe_through :browser

    delete "/logout", SessionController, :delete
  end

  ## Authenticated app routes – everything here requires a logged in user.

  scope "/", SentinelixWeb do
    pipe_through [:browser, :require_authenticated_user]

    # YAML download of the monitors (before /monitors/:id).
    get "/monitors/export", MonitorExportController, :show

    # Add new app LiveViews (dashboard, monitors, notifications, maintenance,
    # status page admin, settings, ...) inside this live_session. They get
    # `@current_scope` assigned; pass it on to `<Layouts.app current_scope={@current_scope}>`.
    live_session :require_authenticated_user,
      on_mount: [{SentinelixWeb.UserAuth, :require_authenticated}, SentinelixWeb.SavedViewsNav] do
      live "/", DashboardLive, :index
      live "/views", SavedViewLive.Index, :index
      live "/views/:slug", DashboardLive, :saved
      live "/views/:slug/edit", SavedViewLive.Index, :edit
      live "/monitors", MonitorLive.Index
      live "/monitors/new", MonitorLive.Form, :new
      live "/monitors/import", MonitorLive.Import
      live "/monitors/:id", MonitorLive.Show
      live "/monitors/:id/edit", MonitorLive.Form, :edit
      live "/monitors/:id/clone", MonitorLive.Form, :clone
      live "/maintenance", MaintenanceLive.Index
      live "/maintenance/new", MaintenanceLive.Form, :new
      live "/maintenance/:id/edit", MaintenanceLive.Form, :edit
      live "/settings/users", Settings.UsersLive
      live "/settings/displays", Settings.DisplaysLive, :index
      live "/settings/displays/new", Settings.DisplaysLive, :new
      live "/settings/displays/:id/edit", Settings.DisplaysLive, :edit

      live "/status-pages", StatusPageLive.Index, :index
      live "/status-pages/new", StatusPageLive.Index, :new
      live "/status-pages/:id", StatusPageLive.Show, :show
      live "/status-pages/:id/edit", StatusPageLive.Show, :edit

      live "/settings/notifications", Live.NotificationSettings, :index
      live "/settings/notifications/new", Live.NotificationSettings, :new
      live "/settings/notifications/:id/edit", Live.NotificationSettings, :edit
    end
  end

  # LiveDashboard (system metrics), available in all environments to
  # logged in users.
  scope "/admin" do
    pipe_through [:browser, :require_authenticated_user]

    live_dashboard "/dashboard",
      metrics: SentinelixWeb.Telemetry,
      on_mount: [{SentinelixWeb.UserAuth, :require_authenticated}]
  end

  # Swoosh mailbox preview in development only.
  if Application.compile_env(:sentinelix, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
