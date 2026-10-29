defmodule Sentinelix.Notifications.Providers.Gotify do
  @moduledoc """
  [Gotify](https://gotify.net) message, authenticated with an application
  token (`X-Gotify-Key`).
  """

  use Sentinelix.Notifications.Provider

  alias Sentinelix.Notifications.{Event, HTTP}

  @impl true
  def label, do: "Gotify"

  @impl true
  def fields do
    [
      %{
        key: "server_url",
        label: "Server URL",
        type: :url,
        required: true,
        placeholder: "https://gotify.example.com"
      },
      %{
        key: "app_token",
        label: "Application token",
        type: :password,
        required: true,
        secret: true
      }
    ]
  end

  @impl true
  def send(channel, event) do
    extras =
      if event.url,
        do: %{"client::notification" => %{"click" => %{"url" => event.url}}},
        else: %{}

    HTTP.request(
      url: String.trim_trailing(channel.config["server_url"], "/") <> "/message",
      headers: [{"x-gotify-key", channel.config["app_token"]}],
      json: %{
        title: Event.title(event),
        message: event |> Event.details() |> Enum.join("\n"),
        priority: priority(event.kind),
        extras: extras
      }
    )
  end

  defp priority(:down), do: 8
  defp priority(:warning), do: 6
  defp priority(_kind), do: 4
end
