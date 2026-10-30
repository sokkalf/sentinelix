defmodule SentinelixWeb.Plugs.ClientIP do
  @moduledoc """
  Sets `conn.remote_ip` to the real client address when the request comes
  through a trusted reverse proxy.

  `X-Forwarded-For` can be set by anyone, so it is only used when the
  direct peer is one of the configured trusted proxies:

      config :sentinelix, :trusted_proxies, ["127.0.0.1", "10.0.0.0/8", "fd00::/8"]

  (`TRUSTED_PROXIES` in production, comma separated). The header is then
  read from right to left, skipping trusted addresses; the first address
  that isn't trusted is the client. Without trusted proxies (the default)
  the header is ignored and the peer address is used as is.

  The client address is used for rate limiting (`Sentinelix.RateLimit`) and
  shows up in the logs.
  """

  @behaviour Plug

  import Bitwise

  @type cidr :: {:inet.ip_address(), non_neg_integer()}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    proxies = Keyword.get_lazy(opts, :trusted_proxies, &trusted_proxies/0)

    if proxies != [] and trusted?(conn.remote_ip, proxies) do
      forwarded =
        conn
        |> Plug.Conn.get_req_header("x-forwarded-for")
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.trim/1)

      %{conn | remote_ip: client_ip(Enum.reverse(forwarded), conn.remote_ip, proxies)}
    else
      conn
    end
  end

  # Walks the forwarded chain from the nearest hop outwards. `current` is the
  # last trusted hop; an unparsable entry ends the walk.
  defp client_ip([], current, _proxies), do: current

  defp client_ip([entry | rest], current, proxies) do
    case parse_address(entry) do
      {:ok, ip} ->
        if trusted?(ip, proxies), do: client_ip(rest, ip, proxies), else: ip

      :error ->
        current
    end
  end

  defp parse_address(entry) do
    case :inet.parse_strict_address(String.to_charlist(entry)) do
      {:ok, ip} -> {:ok, normalize(ip)}
      {:error, _reason} -> :error
    end
  end

  @doc """
  Parses a list of IP addresses and CIDR ranges (`"10.0.0.0/8"`, `"::1"`).

  Returns `{:ok, cidrs}` or `{:error, invalid_entry}`.
  """
  @spec parse_proxies([String.t()]) :: {:ok, [cidr()]} | {:error, String.t()}
  def parse_proxies(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case parse_cidr(String.trim(entry)) do
        {:ok, cidr} -> {:cont, {:ok, [cidr | acc]}}
        :error -> {:halt, {:error, entry}}
      end
    end)
    |> case do
      {:ok, cidrs} -> {:ok, Enum.reverse(cidrs)}
      error -> error
    end
  end

  defp parse_cidr(entry) do
    {address, prefix} =
      case String.split(entry, "/", parts: 2) do
        [address, prefix] -> {address, Integer.parse(prefix)}
        [address] -> {address, :none}
      end

    with {:ok, ip} <- parse_address(address),
         bits = bit_size(ip_to_binary(ip)),
         {:ok, prefix} <- prefix_length(prefix, bits) do
      {:ok, {ip, prefix}}
    end
  end

  defp prefix_length(:none, bits), do: {:ok, bits}
  defp prefix_length({prefix, ""}, bits) when prefix >= 0 and prefix <= bits, do: {:ok, prefix}
  defp prefix_length(_invalid, _bits), do: :error

  @doc """
  Validates the configured trusted proxies, raising on an invalid entry.
  Called on boot so a typo in `TRUSTED_PROXIES` fails fast.
  """
  @spec validate_config!() :: :ok
  def validate_config! do
    trusted_proxies()
    :ok
  end

  defp trusted_proxies do
    raw = Application.get_env(:sentinelix, :trusted_proxies, [])
    key = {__MODULE__, raw}

    case :persistent_term.get(key, nil) do
      nil ->
        case parse_proxies(raw) do
          {:ok, cidrs} ->
            :persistent_term.put(key, cidrs)
            cidrs

          {:error, entry} ->
            raise ArgumentError,
                  "invalid trusted proxy #{inspect(entry)}: expected an IP address or CIDR range"
        end

      cidrs ->
        cidrs
    end
  end

  @doc false
  @spec trusted?(:inet.ip_address(), [cidr()]) :: boolean()
  def trusted?(ip, proxies) do
    address = ip |> normalize() |> ip_to_binary()

    Enum.any?(proxies, fn {network, prefix} ->
      network = ip_to_binary(network)

      bit_size(network) == bit_size(address) and
        prefix_bits(network, prefix) == prefix_bits(address, prefix)
    end)
  end

  defp prefix_bits(binary, prefix) do
    <<bits::bitstring-size(prefix), _rest::bitstring>> = binary
    bits
  end

  # IPv4-mapped IPv6 addresses (::ffff:a.b.c.d, as seen on dual-stack
  # listeners) are compared as IPv4.
  defp normalize({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp normalize(ip), do: ip

  defp ip_to_binary({a, b, c, d}), do: <<a, b, c, d>>

  defp ip_to_binary({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
end
