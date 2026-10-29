defmodule Sentinelix.Notifications.Providers.Ntfy do
  @moduledoc """
  [ntfy](https://ntfy.sh) push notification, published as JSON to the
  server's root URL. An access token (optional) is sent as bearer token.
  """

  use Sentinelix.Notifications.Provider

  alias Sentinelix.Notifications.{Event, HTTP, Provider}

  @impl true
  def label, do: "ntfy"

  @impl true
  def fields do
    [
      %{
        key: "server_url",
        label: "Server URL",
        type: :url,
        required: true,
        default: "https://ntfy.sh",
        placeholder: "https://ntfy.sh"
      },
      %{key: "topic", label: "Topic", type: :text, required: true, placeholder: "my-alerts"},
      %{
        key: "token",
        label: "Access token",
        type: :password,
        secret: true,
        help: "Optional, for protected topics"
      }
    ]
  end

  @impl true
  def validate_config(config) do
    errors =
      case Provider.validate_fields(config, fields()) do
        :ok -> []
        {:error, errors} -> errors
      end

    topic = Provider.blank_to_nil(config["topic"])

    errors =
      if topic && not String.match?(topic, ~r/^[-_A-Za-z0-9]{1,64}$/),
        do: errors ++ [{"topic", "may only contain letters, digits, - and _"}],
        else: errors

    if errors == [], do: :ok, else: {:error, errors}
  end

  @impl true
  def send(channel, event) do
    headers =
      case Provider.blank_to_nil(channel.config["token"]) do
        nil -> []
        token -> [{"authorization", "Bearer " <> token}]
      end

    body =
      %{
        topic: channel.config["topic"],
        title: Event.title(event),
        message: event |> Event.details() |> Enum.join("\n"),
        priority: priority(event.kind),
        tags: [tag(event.kind)]
      }
      |> then(&if(event.url, do: Map.put(&1, :click, event.url), else: &1))

    HTTP.request(
      url: String.trim_trailing(channel.config["server_url"], "/") <> "/",
      headers: headers,
      json: body
    )
  end

  defp priority(:down), do: 5
  defp priority(:warning), do: 4
  defp priority(_kind), do: 3

  defp tag(:down), do: "rotating_light"
  defp tag(:up), do: "white_check_mark"
  defp tag(:warning), do: "warning"
  defp tag(_kind), do: "information_source"
end
