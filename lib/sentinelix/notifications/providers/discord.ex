defmodule Sentinelix.Notifications.Providers.Discord do
  @moduledoc """
  Discord webhook (sends an embed). The webhook URL contains the token, so
  it is treated as a secret.
  """

  use Sentinelix.Notifications.Provider

  alias Sentinelix.Notifications.{Event, HTTP}

  @impl true
  def label, do: "Discord"

  @impl true
  def fields do
    [
      %{
        key: "webhook_url",
        label: "Webhook URL",
        type: :url,
        required: true,
        secret: true,
        placeholder: "https://discord.com/api/webhooks/..."
      }
    ]
  end

  @impl true
  def send(channel, event) do
    embed =
      %{
        title: Event.title(event),
        description: event.message,
        color: color(event.kind),
        timestamp: DateTime.to_iso8601(event.timestamp),
        fields:
          if(event.response_time_ms,
            do: [%{name: "Response time", value: "#{event.response_time_ms} ms", inline: true}],
            else: []
          )
      }
      |> put_if(:url, event.url)

    body = %{
      username: "Sentinelix",
      content: Event.title(event),
      embeds: [embed],
      allowed_mentions: %{parse: []}
    }

    HTTP.request(url: channel.config["webhook_url"], json: body)
  end

  defp color(:down), do: 0xE5484D
  defp color(:up), do: 0x30A46C
  defp color(:warning), do: 0xF5A524
  defp color(_kind), do: 0x3E63DD

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
