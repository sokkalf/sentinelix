defmodule Sentinelix.Checks.Cert do
  @moduledoc """
  TLS certificate expiry check.

  Connects to `host:port` (with SNI, so shared hosts present the right
  certificate), reads the peer certificate and compares its validity period
  with the monitor's `cert_warn_days` and `cert_critical_days`:

  | Certificate                              | Result                         |
  | ---------------------------------------- | ------------------------------ |
  | expires in more than `cert_warn_days`    | `:up`                          |
  | expires within `cert_warn_days`          | `:up` with `warning: true`     |
  | expires within `cert_critical_days`      | `:down`                        |
  | expired or not yet valid                 | `:down`                        |
  | connection / handshake error             | `:down`                        |

  A warning is not a separate check result status: the result is stored as
  `:up` with the warning in its message, and the worker broadcasts
  `{:warning_raised, monitor, result}` when a monitor enters the
  warning state (see `Sentinelix.Monitoring.subscribe_status_changes/0`).
  The remaining days are passed on as `meta: %{days_remaining: n,
  expires_at: datetime}`.

  The chain is deliberately not verified: this check is about expiry, and a
  self-signed or privately issued certificate should be checkable too (use an
  HTTP check with `verify_tls` for chain validation).
  """

  @behaviour Sentinelix.Checks.Check

  alias Sentinelix.Monitoring.{Monitor, Settings}

  @seconds_per_day 86_400

  @impl true
  def run(%Monitor{settings: %Settings{} = settings, timeout_ms: timeout}) do
    started = System.monotonic_time()
    result = fetch_certificate(settings.host, settings.port || 443, timeout)

    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    {status, details} =
      case result do
        {:ok, der} -> evaluate_der(der, settings, DateTime.utc_now())
        {:error, reason} -> {:down, %{message: "TLS connection failed: #{format_error(reason)}"}}
      end

    {status, Map.put(details, :response_time_ms, elapsed_ms)}
  end

  @doc """
  Connects to `host:port` and returns the DER encoded peer certificate.
  """
  @spec fetch_certificate(String.t(), :inet.port_number(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def fetch_certificate(host, port, timeout) do
    host = String.to_charlist(host)

    with {:ok, socket} <- :ssl.connect(host, port, ssl_options(host), timeout) do
      result = :ssl.peercert(socket)
      :ssl.close(socket)
      result
    end
  end

  defp ssl_options(host) do
    sni =
      case :inet.parse_address(host) do
        # SNI must not be sent for IP addresses.
        {:ok, _ip} -> :disable
        {:error, _} -> host
      end

    [
      verify: :verify_none,
      server_name_indication: sni,
      versions: [:"tlsv1.3", :"tlsv1.2"],
      active: false,
      # Failures are reported in the result, don't log every TLS alert.
      log_level: :error
    ]
  end

  @doc """
  Evaluates a DER encoded certificate against the monitor settings at `now`.
  """
  @spec evaluate_der(binary(), Settings.t(), DateTime.t()) :: Sentinelix.Checks.Check.result()
  def evaluate_der(der, settings, now) do
    case validity(der) do
      {:ok, not_before, not_after} -> evaluate(not_before, not_after, settings, now)
      {:error, reason} -> {:down, %{message: "Could not read certificate: #{inspect(reason)}"}}
    end
  end

  @doc """
  Evaluates a certificate validity period against the monitor settings.
  """
  @spec evaluate(DateTime.t(), DateTime.t(), Settings.t(), DateTime.t()) ::
          Sentinelix.Checks.Check.result()
  def evaluate(not_before, not_after, %Settings{} = settings, now) do
    seconds_left = DateTime.diff(not_after, now, :second)
    days = div(seconds_left, @seconds_per_day)
    meta = %{days_remaining: days, expires_at: not_after}
    expiry = Calendar.strftime(not_after, "%Y-%m-%d %H:%M UTC")

    cond do
      DateTime.before?(now, not_before) ->
        {:down,
         %{
           message:
             "Certificate is not valid yet (valid from #{Calendar.strftime(not_before, "%Y-%m-%d %H:%M UTC")})",
           meta: meta
         }}

      seconds_left <= 0 ->
        ago = div(-seconds_left, @seconds_per_day)

        {:down,
         %{message: "Certificate expired #{pluralize_days(ago)} ago (#{expiry})", meta: meta}}

      days <= settings.cert_critical_days ->
        {:down,
         %{message: "Certificate expires in #{pluralize_days(days)} (#{expiry})", meta: meta}}

      days <= settings.cert_warn_days ->
        {:up,
         %{
           message: "Warning: certificate expires in #{pluralize_days(days)} (#{expiry})",
           warning: true,
           meta: meta
         }}

      true ->
        {:up,
         %{message: "Certificate valid for #{pluralize_days(days)} (until #{expiry})", meta: meta}}
    end
  end

  defp pluralize_days(1), do: "1 day"
  defp pluralize_days(n), do: "#{n} days"

  @doc """
  Extracts the validity period (`notBefore`, `notAfter`) of a DER encoded
  certificate.
  """
  @spec validity(binary()) :: {:ok, DateTime.t(), DateTime.t()} | {:error, term()}
  def validity(der) when is_binary(der) do
    case :public_key.pkix_decode_cert(der, :plain) do
      {:Certificate, tbs, _algorithm, _signature} ->
        {:Validity, not_before, not_after} = elem(tbs, 5)

        with {:ok, from} <- parse_time(not_before),
             {:ok, to} <- parse_time(not_after) do
          {:ok, from, to}
        end
    end
  rescue
    error -> {:error, {:invalid_certificate, error}}
  end

  @doc """
  Parses an X.509 `Time` (RFC 5280, 4.1.2.5).

  `utcTime` has a two-digit year (`YYMMDDHHMMSSZ`, years ≥ 50 are 19xx),
  `generalTime` a four-digit year (`YYYYMMDDHHMMSSZ`) and is used for dates
  from 2050 on.
  """
  @spec parse_time({:utcTime | :generalTime, charlist() | String.t()}) ::
          {:ok, DateTime.t()} | {:error, term()}
  def parse_time({:utcTime, value}) do
    case to_string(value) do
      <<yy::binary-2, rest::binary>> ->
        year = String.to_integer(yy)
        century = if year >= 50, do: "19", else: "20"
        parse_general_time(century <> yy <> rest)

      other ->
        {:error, {:invalid_time, other}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_time, value}}
  end

  def parse_time({:generalTime, value}), do: parse_general_time(to_string(value))
  def parse_time(other), do: {:error, {:invalid_time, other}}

  defp parse_general_time(
         <<year::binary-4, month::binary-2, day::binary-2, hour::binary-2, minute::binary-2,
           second::binary-2, "Z">> = value
       ) do
    case DateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}Z") do
      {:ok, datetime, 0} -> {:ok, datetime}
      {:error, _} -> {:error, {:invalid_time, value}}
    end
  end

  defp parse_general_time(value), do: {:error, {:invalid_time, value}}

  defp format_error({:tls_alert, {_alert, description}}),
    do: description |> to_string() |> String.trim()

  defp format_error(:nxdomain), do: "host not found"
  defp format_error(:econnrefused), do: "connection refused"
  defp format_error(:timeout), do: "timed out"
  defp format_error(reason), do: inspect(reason)
end
