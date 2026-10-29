defmodule Sentinelix.Notifications.ProvidersTest do
  use ExUnit.Case, async: true

  import Sentinelix.NotificationsFixtures
  import Swoosh.TestAssertions

  alias Sentinelix.Notifications.{Channel, Event, Provider}
  alias Sentinelix.Notifications.Providers

  @timestamp ~U[2026-10-30 12:34:56Z]

  defp event(kind \\ :down) do
    %Event{
      kind: kind,
      monitor_id: 42,
      monitor_name: "Homepage",
      monitor_type: :http,
      status: :down,
      message: "Unexpected status 503 Service Unavailable",
      response_time_ms: 120,
      status_code: 503,
      timestamp: @timestamp,
      url: "http://localhost:4002/monitors/42"
    }
  end

  defp channel(type, config \\ %{}) do
    %Channel{id: 1, name: "Test", type: type, config: Map.merge(valid_config(type), config)}
  end

  describe "Event" do
    test "renders title and text" do
      assert Event.title(event()) == "[DOWN] Homepage is down"
      assert Event.title(event(:up)) == "[UP] Homepage is back up"

      assert Event.text(event()) ==
               """
               [DOWN] Homepage is down
               Unexpected status 503 Service Unavailable
               Response time: 120 ms
               Time: 2026-10-30 12:34:56 UTC
               http://localhost:4002/monitors/42\
               """
    end
  end

  describe "Email" do
    test "sends a plain text email to all recipients" do
      channel = channel(:email, %{"to" => "a@example.com, b@example.com"})
      assert :ok = Providers.Email.send(channel, event())

      assert_email_sent(fn email ->
        assert email.subject == "[DOWN] Homepage is down"
        assert email.to == [{"", "a@example.com"}, {"", "b@example.com"}]
        assert email.from == {"Sentinelix", "sentinelix@localhost"}
        assert email.text_body =~ "Unexpected status 503"
        assert email.text_body =~ "http://localhost:4002/monitors/42"
      end)
    end

    test "validates the recipients" do
      assert :ok = Providers.Email.validate_config(%{"to" => "a@example.com; b@example.org"})
      assert {:error, [{"to", "can't be blank"}]} = Providers.Email.validate_config(%{})

      assert {:error, [{"to", _}]} =
               Providers.Email.validate_config(%{"to" => "a@example.com, nope"})
    end
  end

  describe "Webhook" do
    test "POSTs the event as JSON with custom headers" do
      capture_requests()

      channel =
        channel(:webhook, %{
          "url" => "https://hooks.example.com/in?x=1",
          "headers" => "Authorization: Bearer s3cret\nX-Env:  prod "
        })

      assert :ok = Providers.Webhook.send(channel, event())
      assert_received {:notification_request, request}

      assert request.method == "POST"
      assert request.url == "https://hooks.example.com/in?x=1"
      assert request.headers["authorization"] == "Bearer s3cret"
      assert request.headers["x-env"] == "prod"
      assert request.headers["content-type"] =~ "application/json"
      assert request.headers["user-agent"] =~ "Sentinelix/"

      assert %{
               "event" => "down",
               "title" => "[DOWN] Homepage is down",
               "monitor" => %{
                 "id" => 42,
                 "name" => "Homepage",
                 "type" => "http",
                 "url" => "http://localhost:4002/monitors/42"
               },
               "status" => "down",
               "message" => "Unexpected status 503 Service Unavailable",
               "response_time_ms" => 120,
               "status_code" => 503,
               "timestamp" => "2026-10-30T12:34:56Z"
             } = request.body
    end

    test "returns an error for non-2xx responses" do
      capture_requests(self(), 500)

      assert {:error, {:http_status, 500, _body}} =
               Providers.Webhook.send(channel(:webhook), event())
    end

    test "validates the URL and headers" do
      assert :ok = Providers.Webhook.validate_config(valid_config(:webhook))

      assert {:error, [{"url", "must be an http(s) URL"}]} =
               Providers.Webhook.validate_config(%{"url" => "ftp://example.com"})

      assert {:error, [{"headers", _}]} =
               Providers.Webhook.validate_config(
                 Map.put(valid_config(:webhook), "headers", "no colon here")
               )
    end
  end

  describe "Slack" do
    test "POSTs text and blocks to the incoming webhook" do
      capture_requests()
      assert :ok = Providers.Slack.send(channel(:slack), event())
      assert_received {:notification_request, request}

      assert request.url == "https://hooks.slack.com/services/T0/B0/x"
      assert request.body["text"] == "[DOWN] Homepage is down"
      assert [title, details] = request.body["blocks"]
      assert title["text"]["text"] == "*[DOWN] Homepage is down*"
      assert details["text"]["type"] == "mrkdwn"
      assert details["text"]["text"] =~ "Response time: 120 ms"
    end
  end

  describe "Discord" do
    test "POSTs an embed to the webhook" do
      capture_requests()
      assert :ok = Providers.Discord.send(channel(:discord), event())
      assert_received {:notification_request, request}

      assert request.url == "https://discord.com/api/webhooks/1/x"
      assert request.body["content"] == "[DOWN] Homepage is down"
      assert request.body["allowed_mentions"] == %{"parse" => []}

      assert [
               %{
                 "title" => "[DOWN] Homepage is down",
                 "description" => "Unexpected status 503 Service Unavailable",
                 "url" => "http://localhost:4002/monitors/42",
                 "color" => 0xE5484D,
                 "timestamp" => "2026-10-30T12:34:56Z",
                 "fields" => [%{"name" => "Response time", "value" => "120 ms"}]
               }
             ] = request.body["embeds"]
    end
  end

  describe "Telegram" do
    test "calls sendMessage of the bot API" do
      capture_requests()
      assert :ok = Providers.Telegram.send(channel(:telegram), event())
      assert_received {:notification_request, request}

      assert request.url == "https://api.telegram.org/bot123456:ABC-def_1/sendMessage"
      assert request.body["chat_id"] == "-100"
      assert request.body["text"] == Event.text(event())
    end

    test "validates the bot token" do
      assert {:error, [{"bot_token", "is not a valid bot token"}]} =
               Providers.Telegram.validate_config(%{"bot_token" => "nope", "chat_id" => "1"})
    end
  end

  describe "ntfy" do
    test "publishes JSON to the server with the token" do
      capture_requests()

      channel = channel(:ntfy, %{"server_url" => "https://ntfy.example.com/", "token" => "tk"})
      assert :ok = Providers.Ntfy.send(channel, event())
      assert_received {:notification_request, request}

      assert request.url == "https://ntfy.example.com/"
      assert request.headers["authorization"] == "Bearer tk"

      assert %{
               "topic" => "alerts",
               "title" => "[DOWN] Homepage is down",
               "priority" => 5,
               "tags" => ["rotating_light"],
               "click" => "http://localhost:4002/monitors/42"
             } = request.body

      assert request.body["message"] =~ "Unexpected status 503"
    end

    test "sends no authorization header without a token" do
      capture_requests()
      assert :ok = Providers.Ntfy.send(channel(:ntfy), event(:up))
      assert_received {:notification_request, request}
      refute Map.has_key?(request.headers, "authorization")
      assert request.body["tags"] == ["white_check_mark"]
    end

    test "validates the topic" do
      assert {:error, [{"topic", _}]} =
               Providers.Ntfy.validate_config(%{
                 "server_url" => "https://ntfy.sh",
                 "topic" => "a/b"
               })
    end
  end

  describe "Gotify" do
    test "POSTs a message with the app token" do
      capture_requests()
      assert :ok = Providers.Gotify.send(channel(:gotify), event())
      assert_received {:notification_request, request}

      assert request.url == "https://gotify.example.com/message"
      assert request.headers["x-gotify-key"] == "AbCdEf"

      assert %{
               "title" => "[DOWN] Homepage is down",
               "priority" => 8,
               "extras" => %{
                 "client::notification" => %{
                   "click" => %{"url" => "http://localhost:4002/monitors/42"}
                 }
               }
             } = request.body
    end
  end

  test "every type has a provider with fields and a label" do
    for type <- Provider.types() do
      provider = Provider.for_type(type)
      assert is_binary(provider.label())
      assert [_ | _] = provider.fields()
      assert provider.validate_config(valid_config(type)) == :ok
    end
  end
end
