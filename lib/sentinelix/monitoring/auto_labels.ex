defmodule Sentinelix.Monitoring.AutoLabels do
  @moduledoc """
  Automatic labels: read-only labels every monitor gets from its
  configuration, so monitors can be grouped and selected without labelling
  them by hand.

    * `type` – the monitor type (`http`, `tcp`, `ping`, `dns`,
      `cert`, `push` or `postgres`).
    * `host` – the host the monitor checks: the host of the URL (http), or the hostname or IP address (tcp, ping, dns, cert,
      postgres), normalized by `normalize_host/1`. Push monitors have none.

  Their keys are reserved (`reserved?/1`): user labels can't use them.

  ## Storage

  Automatic labels are derived on save (`Sentinelix.Monitoring.Monitor`
  stores them in `auto_labels`), and the database keeps the union of user
  and automatic labels in the generated column `all_labels` (with a GIN
  index). Selectors therefore query user and automatic labels the same way,
  in SQL on `all_labels` and in memory on `monitor.all_labels`.
  """

  alias Sentinelix.Monitoring.{Labels, Settings}

  @keys ["host", "type"]

  @doc "The reserved keys of automatic labels."
  @spec keys() :: [Labels.key()]
  def keys, do: @keys

  @doc "Whether `key` is reserved for an automatic label."
  @spec reserved?(Labels.key()) :: boolean()
  def reserved?(key), do: key in @keys

  @doc """
  The automatic labels of a monitor with the given type and settings.

      iex> settings = %Sentinelix.Monitoring.Settings{url: "https://Example.com:8443/health"}
      iex> Sentinelix.Monitoring.AutoLabels.derive(:http, settings)
      %{"host" => "example.com", "type" => "http"}
  """
  @spec derive(atom() | nil, Settings.t() | nil) :: Labels.t()
  def derive(nil, _settings), do: %{}

  def derive(type, settings) do
    case host(type, settings) do
      nil -> %{"type" => Atom.to_string(type)}
      host -> %{"type" => Atom.to_string(type), "host" => host}
    end
  end

  defp host(type, %Settings{url: url}) when type == :http and is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} -> normalize_host(host)
      {:error, _part} -> nil
    end
  end

  defp host(type, %Settings{host: host}) when type in [:tcp, :ping, :dns, :cert, :postgres],
    do: normalize_host(host)

  defp host(_type, _settings), do: nil

  @doc """
  Normalizes a hostname or IP address for the `host` label: trimmed,
  lowercased, without a port, IPv6 brackets or trailing dot. Returns `nil`
  for a blank host or one that isn't a valid label value.

      iex> Sentinelix.Monitoring.AutoLabels.normalize_host("DB1.Example.com.")
      "db1.example.com"

      iex> Sentinelix.Monitoring.AutoLabels.normalize_host("[2001:DB8::1]:443")
      "2001:db8::1"
  """
  @spec normalize_host(String.t() | nil) :: Labels.value() | nil
  def normalize_host(host) when is_binary(host) do
    host =
      host
      |> String.trim()
      |> String.downcase()
      |> strip_port()
      |> String.trim_trailing(".")

    if host != "" and Labels.valid_value?(host), do: host
  end

  def normalize_host(_host), do: nil

  # "[v6]" or "[v6]:port" -> "v6"; "host:port" -> "host". A bare IPv6
  # address (more than one ':') has no port.
  defp strip_port("[" <> rest), do: rest |> String.split("]", parts: 2) |> hd()

  defp strip_port(host) do
    case String.split(host, ":") do
      [name, _port] -> name
      _other -> host
    end
  end
end
