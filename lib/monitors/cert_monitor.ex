defmodule Sentinelix.Monitors.CertMonitor do
  use GenServer
  require Logger

  alias Phoenix.PubSub
  alias Sentinelix.Monitors.CertMonitor

  @moduledoc """
  SSL Monitor
  """

  defstruct [:name, :url, :status, :interval, :retries,
             :last_checked, :last_status, :last_error,
             :expiry_warn_after, :expiry_critical_after,
             :remaining_retries, :last_response]

  @doc """
  Starts the SSL Monitor
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    url = Keyword.get(opts, :url, nil)
    interval = Keyword.get(opts, :interval, 60)
    retries = Keyword.get(opts, :retries, 3)
    expiry_warn_after = Keyword.get(opts, :expiry_warn_after, 30)
    expiry_critical_after = Keyword.get(opts, :expiry_critical_after, 7)
    name = Keyword.get(opts, :name, nil)

    verify_url = fn url ->
      cond do
        url == nil ->
          {:error, "No URL specified"}
        not is_binary(url) ->
          {:error, "URL must be a string"}
        URI.parse(url) ->
          {:ok, url}
      end
    end

    with {:name, true} <- {:name, !is_nil(name) && is_binary(name)},
         {:ok, url} <- verify_url.(url) do
            Logger.info("Starting Cert Monitor")
            tick(interval)
            {:ok, %CertMonitor{
              name: name,
              url: url,
              status: :pending,
              interval: interval,
              retries: retries,
              last_checked: nil,
              last_status: nil,
              last_error: nil,
              expiry_warn_after: expiry_warn_after,
              expiry_critical_after: expiry_critical_after,
              remaining_retries: retries
            }}
    end
  end

  def handle_info(:tick, state) do
    Logger.info("Checking SSL certificate for #{state.url}")
    case check_ssl_expiry(state) do
      {:ok, response} ->
        Logger.info("Cert Monitor OK")
        tick(state.interval)
        if (state.remaining_retries > 1) and (state.status != :ok) do
          {:noreply, %CertMonitor{
            state | status: :pending,
            last_checked: DateTime.utc_now(),
            last_status: state.last_status || :pending,
            last_error: nil,
            last_response: response,
            remaining_retries: state.remaining_retries - 1
          }}
        else
          if state.last_status == :error or state.last_status == :warning do
            alert(:ok, state)
          end
          {:noreply, %CertMonitor{
            state | status: :ok,
            last_checked: DateTime.utc_now(),
            last_status: :ok,
            last_error: nil,
            last_response: response,
            remaining_retries: state.retries
          }}
        end
      {:critical, error} ->
        Logger.error("Cert Monitor critical: #{inspect(error)}")
        tick(state.interval)
        if (state.remaining_retries > 1) and (state.status != :error) do
          {:noreply, %CertMonitor{
            state | status: :pending,
            last_checked: DateTime.utc_now(),
            last_status: state.last_status,
            last_error: error,
            last_response: error,
            remaining_retries: state.remaining_retries - 1
          }}
        else
          if state.last_status == :ok or state.last_status == :warning do
            alert(:error, state)
          end
          {:noreply, %CertMonitor{
            state | status: :error,
            last_checked: DateTime.utc_now(),
            last_status: :error,
            last_error: error,
            last_response: error,
            remaining_retries: state.retries
          }}
        end
      {:warning, warning} ->
        Logger.warning("Cert Monitor warning: #{inspect(warning)}")
        tick(state.interval)
        if (state.remaining_retries > 1) and (state.status != :warning) do
          {:noreply, %CertMonitor{
            state | status: :pending,
            last_checked: DateTime.utc_now(),
            last_status: state.last_status,
            last_error: warning,
            last_response: warning,
            remaining_retries: state.remaining_retries - 1
          }}
        else
          if state.last_status == :error or state.last_status == :ok do
            alert(:warning, state)
          end
          {:noreply, %CertMonitor{
            state | status: :warning,
            last_checked: DateTime.utc_now(),
            last_status: :warning,
            last_error: warning,
            last_response: warning,
            remaining_retries: state.retries
          }}
        end
    end
  end

  def handle_info({:ssl_closed, _}, state) do
    Logger.debug("Cert Monitor: SSL connection closed")
    {:noreply, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  defp alert(status, state) do
    PubSub.broadcast(Sentinelix.PubSub, "CertMonitor_#{state.name}", {status, state})
    case status do
      :ok -> Logger.info("UP Alert goes here")
      :error -> Logger.info("DOWN Alert goes here")
      :warning -> Logger.info("WARN Alert goes here")
    end
  end

  defp check_ssl_expiry(state) do
    expiry_warn_after = state.expiry_warn_after
    expiry_critical_after = state.expiry_critical_after
    case get_ssl_expiry(state.url) do
      {:ok, _valid_from, valid_to} ->
        now = DateTime.utc_now()
        case DateTime.diff(valid_to, now) do
          diff when diff > expiry_warn_after * 24 * 60 * 60 ->
            {:ok, "Certificate is valid until #{valid_to}"}
          diff when diff <= expiry_warn_after * 24 * 60 * 60 and diff > expiry_critical_after * 24 * 60 * 60 ->
            {:warning, "Certificate is valid until #{valid_to}"}
          diff when diff <= expiry_critical_after * 24 * 60 * 60 ->
            {:critical, "Certificate is valid until #{valid_to}"}
          diff when diff < 0 ->
            {:critical, "Certificate has expired"}
          _ ->
            {:critical, "Error checking certificate: unknown"}
        end
      {:error, reason} ->
        {:critical, "Error checking certificate: #{reason}"}
    end
  end

  def get_ssl_expiry(url) do
    # Borrowed from:
    # https://elixirforum.com/t/get-ssl-expiry-date-from-an-http-request-using-mint-finch-mojito/35055/3
    uri = URI.parse(url)

    sslopts = [
        verify: :verify_none,
        cacerts: :public_key.cacerts_get(),
        versions: [:"tlsv1.2"]
    ]

    cert =
      with {:ok, sock} <- :ssl.connect(to_charlist(uri.host), uri.port, sslopts, 30_000),
           {:ok, der} <- :ssl.peercert(sock),
           :ok <- :ssl.close(sock) do
        :public_key.pkix_decode_cert(der, :plain)
      else
        {:error, reason} -> {:error, reason}
      end

    validity = case cert do
      {:error, reason} -> {:error, reason}
      cert ->
        cert
        |> elem(1)
        |> elem(5)
    end

    case validity do
      {:Validity, {:utcTime, valid_from}, {:utcTime, valid_to}} ->
        {:ok, from_cert_time(valid_from), from_cert_time(valid_to)}
      {:error, reason} ->
        {:error, reason}
      smth ->
        {:error, smth}
    end
  end

  defp from_cert_time(cert_time_charlist) do
    case to_string(cert_time_charlist) do
      <<year::binary-2, month::binary-2, day::binary-2, hour::binary-2, minute::binary-2, second::binary-2, tz::binary>> ->
        {:ok, dt, _offset} = DateTime.from_iso8601("20#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}#{tz}")
        dt
      _ ->
        {:error, "Invalid time format"}
    end
  end

  defp tick(interval), do: Process.send_after(self(), :tick, :timer.seconds(interval))
end
