defmodule Sentinelix.Checks.DNS do
  @moduledoc """
  DNS record check.

  Resolves `host` for `dns_record_type` (A, AAAA, CNAME, MX, TXT or NS) with
  `:inet_res`, using the system's resolver configuration or, if set, the
  name server at `dns_resolver` (port 53). The lookup is limited to the
  monitor's `timeout_ms`.

    * Without `expected_value` the check is `:up` if at least one record of
      the type exists.
    * With `expected_value` one of the records must match it: IP addresses
      are compared as addresses (so `::1` matches `0:0:0:0:0:0:0:1`), domain
      names case-insensitively and without a trailing dot, MX records as
      either `"<preference> <exchange>"` or just the exchange, and TXT
      records exactly (multi-string records are concatenated).

  NXDOMAIN, a timeout or any other resolver error is `:down`. The resolved
  values are passed on as `meta: %{records: [String.t()]}`.
  """

  @behaviour Sentinelix.Checks.Check

  alias Sentinelix.Monitoring.{Monitor, Settings}

  @max_shown_records 5
  @record_types %{
    "A" => :a,
    "AAAA" => :aaaa,
    "CNAME" => :cname,
    "MX" => :mx,
    "TXT" => :txt,
    "NS" => :ns
  }

  @impl true
  def run(%Monitor{settings: %Settings{} = settings, timeout_ms: timeout}) do
    started = System.monotonic_time()
    result = lookup(settings.host, settings.dns_record_type, settings.dns_resolver, timeout)

    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    {status, details} =
      case result do
        {:ok, records} -> evaluate(records, settings)
        {:error, reason} -> {:down, %{message: "DNS lookup failed: #{format_error(reason)}"}}
      end

    {status, Map.put(details, :response_time_ms, elapsed_ms)}
  end

  @doc """
  Resolves the records of `type` (e.g. `"MX"`) for `host` and returns their
  values as strings (see `format_record/2`).

  `resolver` is an optional name server IP address.
  """
  @spec lookup(String.t(), String.t(), String.t() | nil, timeout()) ::
          {:ok, [String.t()]} | {:error, term()}
  def lookup(host, type, resolver, timeout) do
    rr_type = record_type(type)

    with {:ok, options} <- resolver_options(resolver),
         {:ok, msg} <-
           :inet_res.resolve(String.to_charlist(host), :in, rr_type, options, timeout) do
      records =
        for rr <- :inet_dns.msg(msg, :anlist), :inet_dns.rr(rr, :type) == rr_type do
          format_record(rr_type, :inet_dns.rr(rr, :data))
        end

      {:ok, records}
    end
  end

  defp record_type(type), do: Map.fetch!(@record_types, type)

  defp resolver_options(nil), do: {:ok, []}

  defp resolver_options(resolver) do
    port = Application.get_env(:sentinelix, __MODULE__, [])[:resolver_port] || 53

    case :inet.parse_strict_address(String.to_charlist(resolver)) do
      {:ok, ip} -> {:ok, nameservers: [{ip, port}], usevc: false}
      {:error, _} -> {:error, :invalid_resolver}
    end
  end

  @doc """
  Formats the data of a resource record as a string.
  """
  @spec format_record(atom(), term()) :: String.t()
  def format_record(type, ip) when type in [:a, :aaaa], do: ip |> :inet.ntoa() |> to_string()
  def format_record(type, name) when type in [:cname, :ns], do: to_string(name)
  def format_record(:mx, {preference, exchange}), do: "#{preference} #{exchange}"
  def format_record(:txt, strings), do: Enum.map_join(strings, &to_string/1)

  @doc """
  Evaluates resolved records against the settings' `expected_value`.
  """
  @spec evaluate([String.t()], Settings.t()) :: Sentinelix.Checks.Check.result()
  def evaluate([], %Settings{} = settings) do
    {:down, %{message: "No #{settings.dns_record_type} records found", meta: %{records: []}}}
  end

  def evaluate(records, %Settings{dns_record_type: type, expected_value: expected}) do
    meta = %{records: records}
    shown = show(records)

    cond do
      expected in [nil, ""] ->
        {:up, %{message: "#{type}: #{shown}", meta: meta}}

      Enum.any?(records, &matches?(type, &1, expected)) ->
        {:up, %{message: "#{type}: #{shown} (matches #{expected})", meta: meta}}

      true ->
        {:down, %{message: "#{type}: #{shown} (expected #{expected})", meta: meta}}
    end
  end

  defp show(records) do
    {shown, rest} = Enum.split(records, @max_shown_records)
    text = Enum.join(shown, ", ")
    if rest == [], do: text, else: "#{text} (+#{length(rest)} more)"
  end

  @doc false
  def matches?(type, record, expected) when type in ["A", "AAAA"] do
    case {parse_ip(record), parse_ip(String.trim(expected))} do
      {{:ok, ip}, {:ok, ip}} -> true
      _ -> false
    end
  end

  def matches?(type, record, expected) when type in ["CNAME", "NS"],
    do: normalize_name(record) == normalize_name(expected)

  def matches?("MX", record, expected) do
    [preference, exchange] = String.split(record, " ", parts: 2)
    expected = expected |> String.trim() |> String.split(~r/\s+/)

    case expected do
      [name] -> normalize_name(name) == normalize_name(exchange)
      [pref, name] -> pref == preference and normalize_name(name) == normalize_name(exchange)
      _ -> false
    end
  end

  def matches?("TXT", record, expected), do: record == expected

  defp parse_ip(value), do: :inet.parse_strict_address(String.to_charlist(value))

  defp normalize_name(name),
    do: name |> String.trim() |> String.trim_trailing(".") |> String.downcase()

  defp format_error(:nxdomain), do: "host not found (NXDOMAIN)"
  defp format_error(:timeout), do: "timed out"
  defp format_error(:servfail), do: "server failure (SERVFAIL)"
  defp format_error(:refused), do: "query refused"
  defp format_error(:econnrefused), do: "connection refused"
  defp format_error(:invalid_resolver), do: "invalid resolver address"
  defp format_error(reason), do: inspect(reason)
end
