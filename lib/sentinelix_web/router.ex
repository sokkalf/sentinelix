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

  ## Public routes – NO authentication.
  #
  # Reserved for later issues; keep everything here free of auth plugs:
  #   * public status pages (#10), e.g. `live "/status/:slug", StatusPageLive`
  #     (browser pipeline, in its own `live_session :public` without the
  #     `:require_authenticated` hook)
  #   * push/heartbeat endpoint (#6), e.g. `get "/api/push/:token"` (api pipeline)
  #
  # scope "/", SentinelixWeb do
  #   pipe_through :api
  # end

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

    # Add new app LiveViews (dashboard, monitors, notifications, maintenance,
    # status page admin, settings, ...) inside this live_session. They get
    # `@current_scope` assigned; pass it on to `<Layouts.app current_scope={@current_scope}>`.
    live_session :require_authenticated_user,
      on_mount: [{SentinelixWeb.UserAuth, :require_authenticated}] do
      live "/", Live.Dashboard
      live "/monitors/:id", Live.Monitor
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
