defmodule Sentinelix.NotificationsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Sentinelix.Notifications`
  context, and for capturing provider HTTP requests.
  """

  alias Sentinelix.Notifications

  def valid_config(:email), do: %{"to" => "ops@example.com"}
  def valid_config(:webhook), do: %{"url" => "https://hooks.example.com/sentinelix"}
  def valid_config(:slack), do: %{"webhook_url" => "https://hooks.slack.com/services/T0/B0/x"}
  def valid_config(:discord), do: %{"webhook_url" => "https://discord.com/api/webhooks/1/x"}
  def valid_config(:telegram), do: %{"bot_token" => "123456:ABC-def_1", "chat_id" => "-100"}
  def valid_config(:ntfy), do: %{"server_url" => "https://ntfy.example.com", "topic" => "alerts"}

  def valid_config(:gotify),
    do: %{"server_url" => "https://gotify.example.com", "app_token" => "AbCdEf"}

  def channel_fixture(type \\ :webhook, attrs \\ %{}) do
    {:ok, channel} =
      attrs
      |> Enum.into(%{
        name: "Channel #{System.unique_integer([:positive])}",
        type: type,
        config: valid_config(type)
      })
      |> Notifications.create_channel()

    channel
  end

  @doc """
  Stubs the notification HTTP client: every request is answered with
  `status` and sent to `pid` as `{:notification_request, map}` with
  `:method`, `:url`, `:headers` and the decoded JSON `:body`.
  """
  def capture_requests(pid \\ self(), status \\ 200) do
    Req.Test.stub(Sentinelix.Notifications, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(pid, {:notification_request, request_info(conn, body)})

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"ok" => status in 200..299})
    end)
  end

  @doc false
  def request_info(conn, body) do
    %{
      method: conn.method,
      url: Plug.Conn.request_url(conn),
      headers: Map.new(conn.req_headers),
      body: decode(body)
    }
  end

  defp decode(""), do: nil

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, json} -> json
      _ -> body
    end
  end
end
