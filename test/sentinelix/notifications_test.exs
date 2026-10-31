defmodule Sentinelix.NotificationsTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures
  import Sentinelix.NotificationsFixtures

  alias Sentinelix.EncryptedMap
  alias Sentinelix.{Monitoring, Notifications}
  alias Sentinelix.Monitoring.{Monitor, Selector}
  alias Sentinelix.Notifications.{Channel, Delivery, Event}

  describe "channels" do
    test "create_channel/1 keeps only the provider's fields, trimmed" do
      assert {:ok, %Channel{} = channel} =
               Notifications.create_channel(%{
                 "name" => " Ops ",
                 "type" => "ntfy",
                 "config" => %{
                   "server_url" => " https://ntfy.sh ",
                   "topic" => "alerts",
                   "token" => "",
                   "bogus" => "x"
                 }
               })

      assert channel.name == "Ops"
      assert channel.enabled
      refute channel.default
      assert channel.config == %{"server_url" => "https://ntfy.sh", "topic" => "alerts"}
      assert Notifications.get_channel!(channel.id).config == channel.config
    end

    test "create_channel/1 accepts atom keys in the config" do
      assert {:ok, channel} =
               Notifications.create_channel(%{
                 name: "Mail",
                 type: :email,
                 config: %{to: "ops@example.com"}
               })

      assert channel.config == %{"to" => "ops@example.com"}
    end

    test "create_channel/1 validates the config with the provider" do
      assert {:error, changeset} =
               Notifications.create_channel(%{name: "x", type: :gotify, config: %{}})

      assert [{"can't be blank", _}] = Channel.config_errors(changeset, "server_url")
      assert [{"can't be blank", _}] = Channel.config_errors(changeset, "app_token")

      assert {:error, changeset} = Notifications.create_channel(%{name: "", type: :email})
      assert %{name: ["can't be blank"], config: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} = Notifications.create_channel(%{name: "x", type: :pager})
      assert %{type: ["is invalid"]} = errors_on(changeset)
    end

    test "the config is encrypted at rest" do
      channel = channel_fixture(:telegram)

      [raw] =
        Repo.all(from c in "notification_channels", where: c.id == ^channel.id, select: c.config)

      refute raw =~ "123456:ABC-def_1"
      assert {:ok, %{"bot_token" => "123456:ABC-def_1"}} = EncryptedMap.decrypt(raw)
    end

    test "an undecryptable config loads as an empty map" do
      channel = channel_fixture(:webhook)

      from(c in "notification_channels", where: c.id == ^channel.id)
      |> Repo.update_all(set: [config: "garbage"])

      ExUnit.CaptureLog.capture_log(fn ->
        assert Notifications.get_channel!(channel.id).config == %{}
      end)
    end

    test "update_channel/2 keeps blank secrets and replaces given ones" do
      channel = channel_fixture(:telegram)

      assert {:ok, channel} =
               Notifications.update_channel(channel, %{
                 "config" => %{"bot_token" => "", "chat_id" => "@alerts"}
               })

      assert channel.config == %{"bot_token" => "123456:ABC-def_1", "chat_id" => "@alerts"}

      assert {:ok, channel} =
               Notifications.update_channel(channel, %{
                 "config" => %{"bot_token" => "999:new", "chat_id" => "@alerts"}
               })

      assert channel.config["bot_token"] == "999:new"

      # without config params the config is left alone
      assert {:ok, channel} = Notifications.update_channel(channel, %{"name" => "Renamed"})
      assert channel.config["bot_token"] == "999:new"
    end

    test "update_channel/2 does not carry secrets over to another type" do
      channel = channel_fixture(:slack)

      assert {:error, changeset} =
               Notifications.update_channel(channel, %{
                 "type" => "discord",
                 "config" => %{"webhook_url" => ""}
               })

      assert [{"can't be blank", _}] = Channel.config_errors(changeset, "webhook_url")
    end

    test "list and delete channels, broadcasting changes" do
      Notifications.subscribe_channels()
      b = channel_fixture(:webhook, %{name: "b"})
      a = channel_fixture(:email, %{name: "A"})
      assert_received {:channel_created, ^b}

      assert Enum.map(Notifications.list_channels(), & &1.id) == [a.id, b.id]

      assert {:ok, _} = Notifications.delete_channel(a)
      assert_received {:channel_deleted, %Channel{id: id}} when id == a.id
      assert Enum.map(Notifications.list_channels(), & &1.id) == [b.id]
    end
  end

  describe "monitor channels" do
    test "put_monitor_channels/2 and list_channels_for_monitor/2" do
      monitor = monitor_fixture()
      other = monitor_fixture()
      a = channel_fixture(:webhook, %{name: "a"})
      b = channel_fixture(:slack, %{name: "b", enabled: false})
      c = channel_fixture(:email, %{name: "c"})

      assert :ok = Notifications.put_monitor_channels(monitor, [a, b.id, 999_999])
      assert :ok = Notifications.put_monitor_channels(other, [c])

      assert Enum.map(Notifications.list_channels_for_monitor(monitor), & &1.id) == [a.id, b.id]
      assert [%{id: id}] = Notifications.list_channels_for_monitor(monitor.id, enabled: true)
      assert id == a.id
      assert Enum.sort(Notifications.monitor_channel_ids(monitor)) == Enum.sort([a.id, b.id])

      assert :ok = Notifications.put_monitor_channels(monitor, [c])
      assert Notifications.monitor_channel_ids(monitor) == [c.id]
      assert Notifications.channel_monitor_counts() == %{c.id => 2}

      assert :ok = Notifications.put_monitor_channels(monitor, [])
      assert Notifications.list_channels_for_monitor(monitor) == []
    end

    test "put_channel_monitors/2" do
      [m1, m2, m3] = for _ <- 1..3, do: monitor_fixture()
      channel = channel_fixture()

      assert :ok = Notifications.put_channel_monitors(channel, [m1, m2.id])
      assert Enum.sort(Notifications.channel_monitor_ids(channel)) == Enum.sort([m1.id, m2.id])

      assert :ok = Notifications.put_channel_monitors(channel, [m3.id])
      assert Notifications.channel_monitor_ids(channel) == [m3.id]
    end

    test "attach_channels/2 and detach_channels/2" do
      [m1, m2, m3] = for _ <- 1..3, do: monitor_fixture()
      [a, b, c] = for _ <- 1..3, do: channel_fixture()
      :ok = Notifications.put_monitor_channels(m1, [a])

      assert :ok = Notifications.attach_channels([m1, m2.id, -1], [a, b.id, -1])
      assert Enum.sort(Notifications.monitor_channel_ids(m1)) == Enum.sort([a.id, b.id])
      assert Enum.sort(Notifications.monitor_channel_ids(m2)) == Enum.sort([a.id, b.id])
      assert Notifications.monitor_channel_ids(m3) == []

      :ok = Notifications.put_monitor_channels(m3, [a, c])
      assert :ok = Notifications.detach_channels([m1, m3], [a.id, c])
      assert Notifications.monitor_channel_ids(m1) == [b.id]
      assert Enum.sort(Notifications.monitor_channel_ids(m2)) == Enum.sort([a.id, b.id])
      assert Notifications.monitor_channel_ids(m3) == []

      assert :ok = Notifications.attach_channels([], [a])
      assert :ok = Notifications.detach_channels([m2], [])
    end

    test "default channels are attached to new monitors" do
      default = channel_fixture(:webhook, %{default: true})
      _other = channel_fixture(:email)

      assert Notifications.list_default_channels() |> Enum.map(& &1.id) == [default.id]

      monitor = monitor_fixture()
      assert Notifications.monitor_channel_ids(monitor) == [default.id]
    end

    test "deleting a monitor or channel removes the assignment" do
      monitor = monitor_fixture()
      channel = channel_fixture()
      :ok = Notifications.put_monitor_channels(monitor, [channel])

      {:ok, _} = Notifications.delete_channel(channel)
      assert Notifications.monitor_channel_ids(monitor) == []
    end
  end

  describe "channel selectors" do
    test "are optional, normalized and refuse status terms" do
      assert channel_fixture().selector == ""

      channel = channel_fixture(:webhook, %{selector: " Env=prod ,name~api "})
      assert channel.selector == "env=prod, name~api"

      assert {:ok, %{selector: ""}} = Notifications.update_channel(channel, %{selector: "  "})
      assert {:ok, %{selector: ""}} = Notifications.update_channel(channel, %{selector: nil})

      assert {:error, changeset} =
               Notifications.update_channel(channel, %{selector: "status=down"})

      assert "status can't be used here at column 1" in errors_on(changeset).selector

      assert {:error, changeset} = Notifications.update_channel(channel, %{selector: "env="})
      assert [_message] = errors_on(changeset).selector
    end

    test "an empty selector routes nothing, unlike an empty selector elsewhere" do
      monitor = monitor_fixture(:http, %{labels: %{"env" => "prod"}})
      channel = channel_fixture()

      assert Selector.matches?(%Selector{}, monitor)
      refute Channel.routes?(channel, monitor)
      assert Channel.parsed_selector(channel) == nil
      assert Notifications.list_routed_channels(monitor) == []
      assert Notifications.selector_monitor_ids(channel) == []
      assert Notifications.channel_monitor_counts() == %{}
    end

    test "a stored selector that no longer parses routes nothing" do
      monitor = monitor_fixture(:http, %{labels: %{"env" => "prod"}})
      channel = channel_fixture()

      {1, _} =
        Repo.update_all(from(c in Channel, where: c.id == ^channel.id), set: [selector: "env="])

      channel = Notifications.get_channel!(channel.id)
      refute Channel.routes?(channel, monitor)
      assert Notifications.list_routed_channels(monitor) == []
      assert Notifications.channel_monitor_counts() == %{}
    end
  end

  describe "routing" do
    test "list_routed_channels/2: attached and selector channels, with the reasons" do
      monitor = monitor_fixture(:http, %{name: "API", labels: %{"env" => "prod"}})
      _other = monitor_fixture(:http, %{labels: %{"env" => "dev"}})

      attached = channel_fixture(:webhook, %{name: "a attached"})
      both = channel_fixture(:webhook, %{name: "b both", selector: "env=prod"})
      routed = channel_fixture(:webhook, %{name: "c routed", selector: "name~ap, env in (prod)"})

      disabled =
        channel_fixture(:webhook, %{name: "d disabled", selector: "env=prod", enabled: false})

      _dev = channel_fixture(:webhook, %{name: "e dev", selector: "env=dev"})
      _unrouted = channel_fixture(:webhook, %{name: "f nothing"})
      :ok = Notifications.put_monitor_channels(monitor, [attached, both])

      routes = Notifications.list_routed_channels(monitor)

      assert Enum.map(routes, fn {channel, reasons} -> {channel.id, reasons} end) == [
               {attached.id, [:explicit]},
               {both.id, [:explicit, :selector]},
               {routed.id, [:selector]},
               {disabled.id, [:selector]}
             ]

      assert Enum.map(Notifications.list_notified_channels(monitor.id), & &1.id) ==
               [attached.id, both.id, routed.id]

      assert [{%{id: id}, [:selector]}] =
               Notifications.list_routed_channels(monitor, enabled: false)

      assert id == disabled.id
    end

    test "uses the monitor's current labels" do
      monitor = monitor_fixture(:http, %{labels: %{"env" => "dev"}})
      channel = channel_fixture(:webhook, %{selector: "env=prod"})
      assert Notifications.list_notified_channels(monitor) == []

      {:ok, _} = Monitoring.update_monitor(monitor, %{labels: %{"env" => "prod"}})

      # The stale struct still has env=dev: the labels are read again.
      assert [%{id: id}] = Notifications.list_notified_channels(monitor)
      assert id == channel.id
    end

    test "selectors match automatic labels" do
      monitor = monitor_fixture(:tcp)
      channel = channel_fixture(:webhook, %{selector: "type=tcp"})
      _http = monitor_fixture(:http)

      assert [{%{id: id}, [:selector]}] = Notifications.list_routed_channels(monitor)
      assert id == channel.id
      assert Notifications.selector_monitor_ids(channel) == [monitor.id]
    end

    test "a deleted monitor has no channels" do
      monitor = monitor_fixture()
      _channel = channel_fixture(:webhook, %{selector: "type"})
      {:ok, _} = Monitoring.delete_monitor(monitor)

      assert Notifications.list_routed_channels(monitor) == []
    end

    test "route_channels/3 routes unsaved monitors in memory" do
      a = channel_fixture(:webhook, %{selector: "env=prod"})
      b = channel_fixture(:webhook, %{selector: "type=http"})
      c = channel_fixture(:webhook)
      monitor = %Monitor{labels: %{"env" => "prod"}, auto_labels: %{}}

      assert Notifications.route_channels([a, b, c], monitor, [c.id]) == [
               {a, [:selector]},
               {c, [:explicit]}
             ]

      monitor = %{monitor | auto_labels: %{"type" => "http"}}

      assert Notifications.route_channels([a, b, c], monitor, [a.id]) == [
               {a, [:explicit, :selector]},
               {b, [:selector]}
             ]
    end

    test "channel_monitor_counts/0 counts attached and routed monitors once" do
      [m1, m2, m3] =
        for env <- ~w(prod prod dev), do: monitor_fixture(:http, %{labels: %{"env" => env}})

      routed = channel_fixture(:webhook, %{selector: "env=prod"})
      attached = channel_fixture()
      _none = channel_fixture(:webhook, %{selector: "env=staging"})
      :ok = Notifications.put_channel_monitors(routed, [m1, m3])
      :ok = Notifications.put_channel_monitors(attached, [m2])

      assert Notifications.channel_monitor_counts() == %{routed.id => 3, attached.id => 1}
      assert Enum.sort(Notifications.selector_monitor_ids(routed)) == Enum.sort([m1.id, m2.id])
    end
  end

  describe "send_monitor_test_notification/2" do
    test "sends to the monitor's enabled channels, attached or routed" do
      capture_requests()
      monitor = monitor_fixture(:http, %{name: "Homepage", labels: %{"env" => "prod"}})
      attached = channel_fixture(:webhook, %{name: "a"})
      routed = channel_fixture(:webhook, %{name: "b", selector: "env=prod"})
      _disabled = channel_fixture(:webhook, %{name: "c", selector: "env", enabled: false})
      _unrouted = channel_fixture(:webhook, %{name: "d"})
      :ok = Notifications.put_monitor_channels(monitor, [attached])

      assert [{a, :ok}, {b, :ok}] = Notifications.send_monitor_test_notification(monitor)
      assert {a.id, b.id} == {attached.id, routed.id}

      for _ <- 1..2 do
        assert_received {:notification_request, %{body: body}}
        assert body["event"] == "test"
        assert body["title"] == "[TEST] Test notification for Homepage"
        assert body["monitor"]["id"] == monitor.id
        assert body["monitor"]["url"] =~ "/monitors/#{monitor.id}"
      end

      refute_received {:notification_request, _}
    end

    test "returns the errors per channel, and nothing without channels" do
      monitor = monitor_fixture()
      assert Notifications.send_monitor_test_notification(monitor) == []

      capture_requests(self(), 500)
      channel = channel_fixture(:webhook, %{selector: "type"})

      assert [{%{id: id}, {:error, {:http_status, 500, _}}}] =
               Notifications.send_monitor_test_notification(monitor)

      assert id == channel.id
    end
  end

  describe "send_test_notification/1" do
    test "sends a test event through the provider" do
      capture_requests()
      channel = channel_fixture(:slack)

      assert :ok = Notifications.send_test_notification(channel)
      assert_received {:notification_request, %{body: %{"text" => "[TEST] Test notification"}}}
    end

    test "returns provider errors" do
      capture_requests(self(), 404)
      channel = channel_fixture(:webhook)

      assert {:error, {:http_status, 404, _}} = Notifications.send_test_notification(channel)
    end
  end

  describe "Delivery" do
    defp fail_then_succeed(failures) do
      counter = :counters.new(1, [])
      test_pid = self()

      Req.Test.stub(Sentinelix.Notifications, fn conn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        send(test_pid, {:attempt, n})

        if n <= failures,
          do: Plug.Conn.send_resp(conn, 502, "bad gateway"),
          else: Req.Test.json(conn, %{})
      end)
    end

    test "retries failures until a send succeeds" do
      fail_then_succeed(2)
      channel = channel_fixture()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Delivery.deliver_with_retry(channel, event(), max_attempts: 3)
        end)

      assert_received {:attempt, 3}
      assert log =~ "attempt 1/3"
      assert log =~ "HTTP 502: bad gateway"
    end

    test "gives up after max_attempts" do
      fail_then_succeed(10)
      channel = channel_fixture()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:http_status, 502, "bad gateway"}} =
                   Delivery.deliver_with_retry(channel, event(), max_attempts: 2)
        end)

      assert_received {:attempt, 2}
      refute_received {:attempt, 3}
      assert log =~ "giving up"
    end

    test "turns provider exceptions into errors" do
      Req.Test.stub(Sentinelix.Notifications, fn _conn -> raise "boom" end)
      channel = channel_fixture()

      assert {:error, %RuntimeError{message: "boom"}} = Delivery.deliver(channel, event())
    end

    test "turns transport errors into errors" do
      Req.Test.stub(Sentinelix.Notifications, &Req.Test.transport_error(&1, :econnrefused))
      channel = channel_fixture()

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Delivery.deliver(channel, event())
    end

    defp event, do: Event.test()
  end
end
