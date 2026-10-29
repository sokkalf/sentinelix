defmodule Sentinelix.Checks.TCPTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Checks.TCP
  alias Sentinelix.Monitoring.Monitor

  defp monitor(host, port, timeout_ms \\ 2_000) do
    %Monitor{}
    |> Monitor.changeset(%{
      name: "test",
      type: :tcp,
      timeout_ms: timeout_ms,
      settings: %{host: host, port: port}
    })
    |> Ecto.Changeset.apply_action!(:insert)
  end

  defp listen(opts) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true] ++ opts)
    {:ok, port} = :inet.port(socket)
    {socket, port}
  end

  # A port that is (almost certainly) closed: bind one, then close it.
  defp closed_port do
    {socket, port} = listen(ip: {127, 0, 0, 1})
    :gen_tcp.close(socket)
    port
  end

  test "is up when the port accepts connections" do
    {socket, port} = listen(ip: {127, 0, 0, 1})

    assert {:up, details} = TCP.run(monitor("127.0.0.1", port))
    assert details.message == "Connected to port #{port}"
    assert is_integer(details.response_time_ms)

    :gen_tcp.close(socket)
  end

  test "resolves hostnames" do
    {socket, port} = listen(ip: {127, 0, 0, 1})
    assert {:up, _} = TCP.run(monitor("localhost", port))
    :gen_tcp.close(socket)
  end

  test "supports IPv6 addresses" do
    case :gen_tcp.listen(0, [:binary, :inet6, active: false, ip: {0, 0, 0, 0, 0, 0, 0, 1}]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        assert {:up, _} = TCP.run(monitor("::1", port))
        :gen_tcp.close(socket)

      {:error, _} ->
        # No IPv6 on this host.
        :ok
    end
  end

  test "is down when the connection is refused" do
    port = closed_port()

    assert {:down, %{message: message, response_time_ms: ms}} =
             TCP.run(monitor("127.0.0.1", port))

    assert message == "Port #{port}: connection refused"
    assert is_integer(ms)
  end

  test "is down for an unknown host" do
    assert {:down, %{message: "Port 80: host not found"}} =
             TCP.run(monitor("does-not-exist.invalid", 80))
  end

  test "formats errors" do
    assert TCP.format_error(:timeout) == "timed out"
    assert TCP.format_error(:eacces) == "permission denied"
    assert TCP.format_error({:weird, 1}) == "{:weird, 1}"
  end
end
