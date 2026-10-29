defmodule Sentinelix.Notifications.Providers.Slack do
  @moduledoc """
  Slack incoming webhook. The webhook URL contains the token, so it is
  treated as a secret.
  """

  use Sentinelix.Notifications.Provider

  alias Sentinelix.Notifications.{Event, HTTP}

  @impl true
  def label, do: "Slack"

  @impl true
  def fields do
    [
      %{
        key: "webhook_url",
        label: "Webhook URL",
        type: :url,
        required: true,
        secret: true,
        placeholder: "https://hooks.slack.com/services/..."
      }
    ]
  end

  @impl true
  def send(channel, event) do
    body = %{
      text: Event.title(event),
      blocks: [
        %{type: "section", text: %{type: "mrkdwn", text: "*#{escape(Event.title(event))}*"}},
        %{
          type: "section",
          text: %{
            type: "mrkdwn",
            text: event |> Event.details() |> Enum.map_join("\n", &escape/1)
          }
        }
      ]
    }

    HTTP.request(url: channel.config["webhook_url"], json: body)
  end

  # https://api.slack.com/reference/surfaces/formatting#escaping
  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
