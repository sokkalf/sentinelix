defmodule Sentinelix.Notifications.Providers.Webhook do
  @moduledoc """
  Generic webhook: POSTs the event as JSON (see
  `Sentinelix.Notifications.Event.to_map/1`) with optional custom headers
  (one `Name: value` per line).
  """

  use Sentinelix.Notifications.Provider

  alias Sentinelix.Notifications.{Event, HTTP, Provider}

  @impl true
  def label, do: "Webhook"

  @impl true
  def fields do
    [
      %{
        key: "url",
        label: "URL",
        type: :url,
        required: true,
        placeholder: "https://example.com/hooks/sentinelix"
      },
      %{
        key: "headers",
        label: "Custom headers",
        type: :textarea,
        secret: true,
        placeholder: "Authorization: Bearer ...",
        help: "Optional, one \"Name: value\" per line"
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

    errors =
      case parse_headers(config["headers"]) do
        {:ok, _headers} -> errors
        :error -> errors ++ [{"headers", "must be one \"Name: value\" per line"}]
      end

    if errors == [], do: :ok, else: {:error, errors}
  end

  @impl true
  def send(channel, event) do
    {:ok, headers} = parse_headers(channel.config["headers"])
    HTTP.request(url: channel.config["url"], headers: headers, json: Event.to_map(event))
  end

  @doc false
  def parse_headers(nil), do: {:ok, []}

  def parse_headers(text) when is_binary(text) do
    text
    |> String.split(~r/\R/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_header/1)
    |> then(fn headers ->
      if :error in headers, do: :error, else: {:ok, headers}
    end)
  end

  defp parse_header(line) do
    with [name, value] <- String.split(line, ":", parts: 2),
         name = String.trim(name),
         true <- String.match?(name, ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/) do
      {name, String.trim(value)}
    else
      _ -> :error
    end
  end
end
