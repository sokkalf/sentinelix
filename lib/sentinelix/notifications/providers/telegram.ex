defmodule Sentinelix.Notifications.Providers.Telegram do
  @moduledoc """
  Telegram bot message (`sendMessage` of the Bot API) to a chat id.
  """

  use Sentinelix.Notifications.Provider

  alias Sentinelix.Notifications.{Event, HTTP, Provider}

  @api_url "https://api.telegram.org"

  @impl true
  def label, do: "Telegram"

  @impl true
  def fields do
    [
      %{
        key: "bot_token",
        label: "Bot token",
        type: :password,
        required: true,
        secret: true,
        placeholder: "123456:ABC-DEF..."
      },
      %{
        key: "chat_id",
        label: "Chat ID",
        type: :text,
        required: true,
        placeholder: "-1001234567890 or @channelname"
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

    token = Provider.blank_to_nil(config["bot_token"])

    errors =
      if token && not String.match?(token, ~r/^\d+:[\w-]+$/),
        do: errors ++ [{"bot_token", "is not a valid bot token"}],
        else: errors

    if errors == [], do: :ok, else: {:error, errors}
  end

  @impl true
  def send(channel, event) do
    HTTP.request(
      url: "#{@api_url}/bot#{channel.config["bot_token"]}/sendMessage",
      json: %{
        chat_id: channel.config["chat_id"],
        text: Event.text(event),
        link_preview_options: %{is_disabled: true}
      }
    )
  end
end
