defmodule Sentinelix.Checks.TCP do
  @moduledoc """
  TCP port check.

  Opens a TCP connection to `host:port` within the monitor's `timeout_ms`
  and closes it again. The target is `:up` if the connection is accepted;
  the response time is the time it took to connect (including DNS
  resolution). IPv6 addresses are supported, and hostnames without an IPv4
  address are retried over IPv6.
  """

  @behaviour Sentinelix.Checks.Check

  alias Sentinelix.Monitoring.{Monitor, Settings}

  @impl true
  def run(%Monitor{settings: %Settings{host: host, port: port}, timeout_ms: timeout}) do
    started = System.monotonic_time()
    result = connect(host, port, timeout)

    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    case result do
      :ok ->
        {:up, %{response_time_ms: elapsed_ms, message: "Connected to port #{port}"}}

      {:error, reason} ->
        {:down, %{response_time_ms: elapsed_ms, message: "Port #{port}: #{format_error(reason)}"}}
    end
  end

  @doc """
  Connects to `host:port` and closes the connection again.
  """
  @spec connect(String.t(), :inet.port_number(), timeout()) :: :ok | {:error, term()}
  def connect(host, port, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case address(host) do
      {:ok, ip} ->
        do_connect(ip, port, [family(ip)], timeout)

      :hostname ->
        name = String.to_charlist(host)

        case do_connect(name, port, [:inet], timeout) do
          {:error, :nxdomain} ->
            remaining = max(deadline - System.monotonic_time(:millisecond), 0)
            do_connect(name, port, [:inet6], remaining)

          result ->
            result
        end
    end
  end

  defp do_connect(address, port, opts, timeout) do
    case :gen_tcp.connect(address, port, [:binary, active: false] ++ opts, timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp address(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :hostname
    end
  end

  defp family(ip) when tuple_size(ip) == 4, do: :inet
  defp family(ip) when tuple_size(ip) == 8, do: :inet6

  @doc false
  def format_error(:econnrefused), do: "connection refused"
  def format_error(:timeout), do: "timed out"
  def format_error(:nxdomain), do: "host not found"
  def format_error(:ehostunreach), do: "host unreachable"
  def format_error(:enetunreach), do: "network unreachable"
  def format_error(:econnreset), do: "connection reset"

  def format_error(reason) when is_atom(reason) do
    case :inet.format_error(reason) do
      ~c"unknown POSIX error" ++ _ -> inspect(reason)
      message -> to_string(message)
    end
  end

  def format_error(reason), do: inspect(reason)
end
