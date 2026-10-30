defmodule Sentinelix.NotificationsTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures
  import Sentinelix.NotificationsFixtures

  alias Sentinelix.EncryptedMap
  alias Sentinelix.Notifications
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
