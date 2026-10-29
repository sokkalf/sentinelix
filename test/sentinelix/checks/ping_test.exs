defmodule Sentinelix.Checks.PingTest do
  use ExUnit.Case, async: false

  alias Sentinelix.Checks.Ping
  alias Sentinelix.Monitoring.Monitor

  # Captured `ping -n -c 1 -W 1 <host>` output (iputils and busybox).
  @iputils_reply """
  PING 192.0.2.10 (192.0.2.10) 56(84) bytes of data.
  64 bytes from 192.0.2.10: icmp_seq=1 ttl=57 time=12.7 ms

  --- 192.0.2.10 ping statistics ---
  1 packets transmitted, 1 received, 0% packet loss, time 0ms
  rtt min/avg/max/mdev = 12.716/12.716/12.716/0.000 ms
  """

  @iputils_fast_reply """
  PING 127.0.0.1 (127.0.0.1) 56(84) bytes of data.
  64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.036 ms

  --- 127.0.0.1 ping statistics ---
  1 packets transmitted, 1 received, 0% packet loss, time 0ms
  rtt min/avg/max/mdev = 0.036/0.036/0.036/0.000 ms
  """

  @iputils_no_reply """
  PING 192.0.2.1 (192.0.2.1) 56(84) bytes of data.

  --- 192.0.2.1 ping statistics ---
  1 packets transmitted, 0 received, 100% packet loss, time 0ms

  """

  @iputils_unknown_host "ping: does-not-exist.invalid: Name or service not known\n"

  @iputils_no_permission "ping: socktype: SOCK_RAW\nping: socket: Operation not permitted\n"

  @busybox_reply """
  PING 192.0.2.10 (192.0.2.10): 56 data bytes
  64 bytes from 192.0.2.10: seq=0 ttl=57 time=8.512 ms

  --- 192.0.2.10 ping statistics ---
  1 packets transmitted, 1 packets received, 0% packet loss
  round-trip min/avg/max = 8.512/8.512/8.512 ms
  """

  @busybox_unknown_host "ping: bad address 'does-not-exist.invalid'\n"

  defp monitor(host, timeout_ms \\ 2_000) do
    %Monitor{}
    |> Monitor.changeset(%{
      name: "test",
      type: :ping,
      timeout_ms: timeout_ms,
      settings: %{host: host}
    })
    |> Ecto.Changeset.apply_action!(:insert)
  end

  describe "parse_output/2" do
    test "a reply is up with the round trip time" do
      assert {:up, details} = Ping.parse_output(@iputils_reply, 0)
      assert details.response_time_ms == 13
      assert details.message == "Reply in 13 ms"
      assert details.meta == %{rtt_ms: 12.7}

      assert {:up, %{response_time_ms: 0, message: "Reply in 0.04 ms"}} =
               Ping.parse_output(@iputils_fast_reply, 0)

      assert {:up, %{response_time_ms: 9, meta: %{rtt_ms: 8.512}}} =
               Ping.parse_output(@busybox_reply, 0)
    end

    test "a reply without a parsable time is still up" do
      assert {:up, %{message: "Reply received"} = details} = Ping.parse_output("weird\n", 0)
      refute Map.has_key?(details, :response_time_ms)
    end

    test "no reply is down" do
      assert {:down, %{message: "No reply (100% packet loss)"}} =
               Ping.parse_output(@iputils_no_reply, 1)
    end

    test "errors are down with the error message" do
      assert {:down, %{message: "ping: does-not-exist.invalid: Name or service not known"}} =
               Ping.parse_output(@iputils_unknown_host, 2)

      assert {:down, %{message: "ping: socket: Operation not permitted"}} =
               Ping.parse_output(@iputils_no_permission, 2)

      assert {:down, %{message: "ping: bad address 'does-not-exist.invalid'"}} =
               Ping.parse_output(@busybox_unknown_host, 1)

      assert {:down, %{message: "ping failed with exit status 2"}} = Ping.parse_output("", 2)
    end
  end

  test "builds the command arguments with the host as a separate, last argument" do
    assert Ping.args("example.com", 2_000) == ["-n", "-c", "1", "-W", "2", "example.com"]
    assert Ping.args("example.com", 2_500) == ["-n", "-c", "1", "-W", "3", "example.com"]
    assert Ping.args("::1", 100) == ["-n", "-c", "1", "-W", "1", "::1"]
  end

  test "never passes a host that looks like an option" do
    # The changeset rejects such hosts; the check refuses them too.
    monitor = put_in(monitor("example.com").settings.host, "-f")
    assert {:down, %{message: "Invalid host"}} = Ping.run(monitor)
  end

  describe "run/1" do
    setup do
      on_exit(fn -> Application.delete_env(:sentinelix, Ping) end)
    end

    test "reports a missing ping executable" do
      Application.put_env(:sentinelix, Ping, executable: "sentinelix-no-such-ping")

      assert {:down, %{message: "The ping command is not available on this system"}} =
               Ping.run(monitor("127.0.0.1"))
    end

    @tag :tmp_dir
    test "runs the configured executable and parses its output", %{tmp_dir: dir} do
      script = Path.join(dir, "fake-ping")

      File.write!(script, """
      #!/bin/sh
      echo "args: $*"
      echo "64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=4.2 ms"
      """)

      File.chmod!(script, 0o755)
      Application.put_env(:sentinelix, Ping, executable: script)

      assert {:up, %{response_time_ms: 4, meta: %{rtt_ms: 4.2}}} =
               Ping.run(monitor("127.0.0.1", 1_500))
    end

    @tag :tmp_dir
    test "reports the error output of a failing executable", %{tmp_dir: dir} do
      script = Path.join(dir, "fake-ping")

      File.write!(script, """
      #!/bin/sh
      echo "ping: $6: Name or service not known" >&2
      exit 2
      """)

      File.chmod!(script, 0o755)
      Application.put_env(:sentinelix, Ping, executable: script)

      assert {:down, %{message: "ping: nope.invalid: Name or service not known"}} =
               Ping.run(monitor("nope.invalid"))
    end
  end
end
