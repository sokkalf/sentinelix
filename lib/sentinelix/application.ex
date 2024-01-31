defmodule Sentinelix.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      SentinelixWeb.Telemetry,
      # Start the Ecto repository
      Sentinelix.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: Sentinelix.PubSub},
      # Start Finch
      {Finch, name: Sentinelix.Finch},
      # Start the Endpoint (http/https)
      SentinelixWeb.Endpoint
      # Start a worker by calling: Sentinelix.Worker.start_link(arg)
      # {Sentinelix.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
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
