defmodule Sentinelix.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Sentinelix.Accounts
  alias Sentinelix.Auth.OIDC

  @impl true
  def start(_type, _args) do
    # OIDC provider discovery/JWKS worker (only when OIDC is configured)
    children =
      [
        SentinelixWeb.Telemetry,
        Sentinelix.Repo,
        # Creates the local admin from ADMIN_EMAIL/ADMIN_PASSWORD if needed
        {Task, &Accounts.ensure_bootstrap_admin/0},
        {Phoenix.PubSub, name: Sentinelix.PubSub},
        {Finch, name: Sentinelix.Finch}
      ] ++
        OIDC.children() ++
        [
          # Started before the engine so no status change goes unnoticed
          {Sentinelix.Notifications.Supervisor,
           Application.get_env(:sentinelix, Sentinelix.Notifications.Supervisor, [])},
          # Maintenance windows, consulted by the engine after every check
          {Sentinelix.Maintenance.Cache,
           Application.get_env(:sentinelix, Sentinelix.Maintenance.Cache, [])},
          {Sentinelix.Monitoring.Supervisor,
           Application.get_env(:sentinelix, Sentinelix.Monitoring.Supervisor, [])},
          # Hourly rollups and data retention
          {Sentinelix.Stats.Scheduler,
           Application.get_env(:sentinelix, Sentinelix.Stats.Scheduler, [])},
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
