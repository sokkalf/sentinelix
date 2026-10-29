defmodule Sentinelix.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # OIDC provider discovery/JWKS worker (only when OIDC is configured)
    children =
      [
        SentinelixWeb.Telemetry,
        Sentinelix.Repo,
        # Creates the local admin from ADMIN_EMAIL/ADMIN_PASSWORD if needed
        {Task, &Sentinelix.Accounts.ensure_bootstrap_admin/0},
        {Phoenix.PubSub, name: Sentinelix.PubSub},
        {Finch, name: Sentinelix.Finch}
      ] ++
        Sentinelix.Auth.OIDC.children() ++
        [
          {SentinelixWeb.Services.MonitorService, []},
          Supervisor.child_spec({Cachex, name: :monitor_cache}, id: :monitor_cache),
          # Start to serve requests, typically the last entry
          SentinelixWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sentinelix.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SentinelixWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
