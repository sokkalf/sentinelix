defmodule Sentinelix.Checks.Ping do
  @moduledoc """
  ICMP ping check.

  OTP has no unprivileged ICMP sockets, so this runs the system `ping`
  binary (iputils or busybox, as found on Linux) once:

      ping -n -c 1 -W <seconds> <host>

  The host is passed as a separate argument (no shell is involved) and must
  be a valid hostname or IP address that doesn't start with `-` (enforced by
  `Sentinelix.Monitoring.Settings` and checked again here), so it can't be
  mistaken for an option. The wait time is the monitor's `timeout_ms`
  rounded up to whole seconds.

  The round trip time is parsed from the output (`time=12.3 ms`) and
  reported as `response_time_ms` (rounded) and as `meta: %{rtt_ms: float}`.
  If no `ping` executable is found, the check is `:down` with a message
  saying so.

  The executable (a name looked up in `PATH`, or a path) can be configured
  with `config :sentinelix, Sentinelix.Checks.Ping, executable: "/usr/bin/ping"`.
  """

  @behaviour Sentinelix.Checks.Check

  alias Sentinelix.Monitoring.{Monitor, Settings}

  @impl true
  def run(%Monitor{settings: %Settings{host: host}, timeout_ms: timeout}) do
    with :ok <- validate_host(host),
         {:ok, executable} <- executable() do
      {output, exit_status} =
        System.cmd(executable, args(host, timeout),
          stderr_to_stdout: true,
          env: [{"LC_ALL", "C"}]
        )

      parse_output(output, exit_status)
    end
  end

  @doc false
  @spec args(String.t(), pos_integer()) :: [String.t()]
  def args(host, timeout_ms) do
    wait_seconds = max(div(timeout_ms + 999, 1000), 1)
    ["-n", "-c", "1", "-W", Integer.to_string(wait_seconds), host]
  end

  defp validate_host("-" <> _), do: {:down, %{message: "Invalid host"}}
  defp validate_host(host) when is_binary(host) and host != "", do: :ok
  defp validate_host(_host), do: {:down, %{message: "Invalid host"}}

  defp executable do
    name = Application.get_env(:sentinelix, __MODULE__, [])[:executable] || "ping"

    case System.find_executable(name) do
      nil -> {:down, %{message: "The ping command is not available on this system"}}
      path -> {:ok, path}
    end
  end

  @doc """
  Turns the output and exit status of `ping -c 1` into a check result.

  Exit status 0 means a reply was received; 1 with packet statistics means
  no reply; anything else is an error (unknown host, missing permissions, …)
  described by the last line of the output.
  """
  @spec parse_output(String.t(), non_neg_integer()) :: Sentinelix.Checks.Check.result()
  def parse_output(output, 0) do
    case rtt(output) do
      {:ok, rtt} ->
        {:up,
         %{
           response_time_ms: round(rtt),
           message: "Reply in #{format_rtt(rtt)} ms",
           meta: %{rtt_ms: rtt}
         }}

      :error ->
        {:up, %{message: "Reply received"}}
    end
  end

  def parse_output(output, exit_status) do
    if exit_status == 1 and output =~ "packet loss",
      do: {:down, %{message: "No reply (100% packet loss)"}},
      else: error_result(output, exit_status)
  end

  # e.g. busybox also exits with 1 for unknown hosts.
  defp error_result(output, exit_status) do
    message =
      case last_line(output) do
        nil -> "ping failed with exit status #{exit_status}"
        line -> line
      end

    {:down, %{message: message}}
  end

  @rtt ~r/time[=<]\s*(\d+(?:\.\d+)?)\s*ms/

  defp rtt(output) do
    case Regex.run(@rtt, output) do
      [_, value] -> {:ok, parse_float(value)}
      nil -> :error
    end
  end

  defp parse_float(value) do
    {float, ""} = Float.parse(value)
    float
  end

  defp format_rtt(rtt) when rtt >= 10, do: :erlang.float_to_binary(rtt, decimals: 0)
  defp format_rtt(rtt), do: :erlang.float_to_binary(rtt, decimals: 2)

  defp last_line(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
  end
end
