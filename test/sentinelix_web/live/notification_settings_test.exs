defmodule SentinelixWeb.Live.NotificationSettingsTest do
  use SentinelixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sentinelix.MonitoringFixtures
  import Sentinelix.NotificationsFixtures
  import Swoosh.TestAssertions

  alias Sentinelix.Notifications

  test "requires a logged in user", %{conn: conn} do
    assert conn |> get(~p"/settings/notifications") |> redirected_to() == ~p"/login"
  end

  describe "logged in" do
    setup :register_and_log_in_user

    test "lists channels without their secrets", %{conn: conn} do
      channel_fixture(:ntfy, %{
        name: "Phone",
        default: true,
        config: %{
          "server_url" => "https://ntfy.example.com",
          "topic" => "ops",
          "token" => "tk_s3cret"
        }
      })

      channel_fixture(:slack, %{name: "Team chat", enabled: false})

      {:ok, view, html} = live(conn, ~p"/settings/notifications")
      assert html =~ "Phone"
      assert html =~ "ntfy"
      assert html =~ "https://ntfy.example.com · ops"
      assert html =~ "default"
      assert html =~ "Team chat"
      refute html =~ "tk_s3cret"
      refute html =~ "hooks.slack.com"
      assert view |> element("#channels") |> render() =~ "disabled"
    end

    test "shows an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")
      assert has_element?(view, "#no-channels")
    end

    test "creates a channel with provider specific fields and monitors", %{conn: conn} do
      monitor = monitor_fixture(:http, %{name: "API"})
      _other = monitor_fixture(:http, %{name: "Other"})

      {:ok, view, _html} = live(conn, ~p"/settings/notifications")
      view |> element("#new-channel") |> render_click()
      assert_patch(view, ~p"/settings/notifications/new")
      refute has_element?(view, "#provider-fields")

      # choosing a type renders its fields
      html = view |> form("#channel-form", channel: %{type: "telegram"}) |> render_change()
      assert html =~ "Bot token"
      assert html =~ "Chat ID"

      html =
        view
        |> form("#channel-form",
          channel: %{name: "Bot", type: "telegram", config: %{"bot_token" => "nope"}}
        )
        |> render_submit()

      assert html =~ "is not a valid bot token"

      view
      |> form("#channel-form",
        channel: %{
          name: "Bot",
          type: "telegram",
          config: %{"bot_token" => "123:abc", "chat_id" => "42"}
        },
        monitor_ids: [to_string(monitor.id)]
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/notifications")
      assert render(view) =~ "Notification channel &quot;Bot&quot; saved"

      [channel] = Notifications.list_channels()
      assert channel.type == :telegram
      assert channel.config == %{"bot_token" => "123:abc", "chat_id" => "42"}
      assert Notifications.channel_monitor_ids(channel) == [monitor.id]
    end

    test "edits a channel, keeping secrets that are left blank", %{conn: conn} do
      monitor = monitor_fixture()
      channel = channel_fixture(:gotify, %{name: "Gotify"})
      :ok = Notifications.put_channel_monitors(channel, [monitor])

      {:ok, view, html} = live(conn, ~p"/settings/notifications/#{channel.id}/edit")
      refute html =~ "AbCdEf"
      assert html =~ "Saved – leave blank to keep"
      assert html =~ "https://gotify.example.com"

      view
      |> form("#channel-form",
        channel: %{
          name: "Gotify home",
          config: %{"server_url" => "https://push.example.com", "app_token" => ""}
        },
        monitor_ids: [""]
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/notifications")

      channel = Notifications.get_channel!(channel.id)
      assert channel.name == "Gotify home"

      assert channel.config == %{
               "server_url" => "https://push.example.com",
               "app_token" => "AbCdEf"
             }

      assert Notifications.channel_monitor_ids(channel) == []
    end

    test "routes monitors by selector, marking the ones it matches", %{conn: conn} do
      prod = monitor_fixture(:http, %{name: "API", labels: %{"env" => "prod"}})
      _dev = monitor_fixture(:http, %{name: "Dev", labels: %{"env" => "dev"}})
      attached = monitor_fixture(:http, %{name: "Other"})
      channel = channel_fixture(:webhook, %{name: "Hook"})

      {:ok, view, _html} = live(conn, ~p"/settings/notifications/#{channel.id}/edit")
      refute has_element?(view, "#channel-routed-count")

      # status terms are refused, the event already is a status change
      html = view |> form("#channel-form", channel: %{selector: "status=down"}) |> render_change()
      assert html =~ "status can&#39;t be used here at column 1"
      refute has_element?(view, "#channel-routed-count")

      # completion offers label values, not statuses
      view |> form("#channel-form", channel: %{selector: "env=p"}) |> render_change()
      assert has_element?(view, ~s(#channel_selector-suggestions option[value="env=prod"]))

      html =
        view |> form("#channel-form", channel: %{selector: "status"}) |> render_change()

      refute html =~ ~s(value="status=down")

      view |> form("#channel-form", channel: %{selector: "Env=prod"}) |> render_change()
      assert view |> element("#channel-routed-count") |> render() =~ "matches 1 monitor"
      assert has_element?(view, "#monitor-#{prod.id}-routed")
      refute has_element?(view, "#monitor-#{attached.id}-routed")

      view
      |> form("#channel-form",
        channel: %{selector: "Env=prod"},
        monitor_ids: [to_string(attached.id)]
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/notifications")
      channel = Notifications.get_channel!(channel.id)
      assert channel.selector == "env=prod"
      assert Notifications.channel_monitor_ids(channel) == [attached.id]

      # the list counts attached and routed monitors and shows the selector
      assert view |> element("#channel-#{channel.id}") |> render() =~ "2"
      assert view |> element("#channel-#{channel.id}-selector") |> render() =~ "env=prod"

      # an empty selector routes nothing
      {:ok, view, _html} = live(conn, ~p"/settings/notifications/#{channel.id}/edit")
      assert has_element?(view, "#monitor-#{prod.id}-routed")
      view |> form("#channel-form", channel: %{selector: ""}) |> render_submit()
      assert Notifications.get_channel!(channel.id).selector == ""
      assert Notifications.channel_monitor_counts() == %{channel.id => 1}
    end

    test "does not save an invalid selector", %{conn: conn} do
      channel = channel_fixture(:webhook, %{selector: "env=prod"})
      {:ok, view, _html} = live(conn, ~p"/settings/notifications/#{channel.id}/edit")

      html = view |> form("#channel-form", channel: %{selector: "env="}) |> render_submit()
      assert html =~ "expected a value"
      assert Notifications.get_channel!(channel.id).selector == "env=prod"
    end

    test "redirects for unknown channels", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/settings/notifications", flash: flash}}} =
               live(conn, ~p"/settings/notifications/999999/edit")

      assert flash["error"] == "Notification channel not found"
    end

    test "toggles and deletes channels", %{conn: conn} do
      channel = channel_fixture(:webhook, %{name: "Hook"})
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      view |> element("#toggle-channel-#{channel.id}") |> render_click()
      refute Notifications.get_channel!(channel.id).enabled
      assert view |> element("#toggle-channel-#{channel.id}") |> render() =~ "disabled"

      view |> element("#delete-channel-#{channel.id}") |> render_click()
      assert Notifications.get_channel(channel.id) == nil
      refute has_element?(view, "#channel-#{channel.id}")
    end

    test "sends a test notification from the list", %{conn: conn} do
      channel = channel_fixture(:email, %{name: "Mail", config: %{"to" => "me@example.com"}})
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      view |> element("#test-channel-#{channel.id}") |> render_click()
      assert render_async(view) =~ "Test notification sent to Mail"
      assert_email_sent(subject: "[TEST] Test notification")
    end

    test "reports a failing test notification", %{conn: conn} do
      capture_requests(self(), 401)
      channel = channel_fixture(:slack, %{name: "Slack"})
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      view |> element("#test-channel-#{channel.id}") |> render_click()
      assert render_async(view) =~ "Test notification to Slack failed: HTTP 401"
    end

    test "sends a test notification with the unsaved form values", %{conn: conn} do
      capture_requests()
      channel = channel_fixture(:discord, %{name: "Discord"})
      {:ok, view, _html} = live(conn, ~p"/settings/notifications/#{channel.id}/edit")

      view
      |> form("#channel-form", channel: %{name: "Renamed"})
      |> render_submit(%{"action" => "test"})

      assert render_async(view) =~ "Test notification sent to Renamed"
      assert_received {:notification_request, %{url: "https://discord.com/api/webhooks/1/x"}}
      # nothing was saved
      assert Notifications.get_channel!(channel.id).name == "Discord"
    end
  end
end
