defmodule Sentinelix.Monitors.HTTPMonitor do
  use GenServer
  require Logger

  alias Sentinelix.Monitors.HTTPMonitor

  @moduledoc """
  HTTP Monitor
  """

  defstruct [:name, :url, :status, :interval, :retries,
             :last_checked, :last_status, :last_error,
             :verify_ssl, :follow_redirects, :check_certificate,
             :expiry_warn_after, :expiry_critical_after,
             :remaining_retries]

  @doc """
  Starts the HTTP Monitor
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    url = Keyword.get(opts, :url, nil)
    interval = Keyword.get(opts, :interval, 60)
    retries = Keyword.get(opts, :retries, 3)
    verify_ssl = Keyword.get(opts, :verify_ssl, true)
    follow_redirects = Keyword.get(opts, :follow_redirects, false)
    check_certificate = Keyword.get(opts, :check_certificate, false)
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
         {:ok, url} <- verify_url.(url),
         {:cert_check, true} <- {:cert_check, check_certificate != verify_ssl} do
            Logger.info("Starting HTTP Monitor")
            tick(interval)
            {:ok, %HTTPMonitor{
              name: name,
              url: url,
              status: :pending,
              interval: interval,
              retries: retries,
              last_checked: nil,
              last_status: nil,
              last_error: nil,
              verify_ssl: verify_ssl,
              follow_redirects: follow_redirects,
              check_certificate: check_certificate,
              expiry_warn_after: expiry_warn_after,
              expiry_critical_after: expiry_critical_after,
              remaining_retries: retries
            }}
      else
        {:error, error} ->
          {:stop, {:error, error}}
        {:cert_check, false} ->
          {:stop, {:error, "Certificate check requires SSL verification"}}
        {:name, false} ->
          {:stop, {:error, "Name must be a string"}}
      end
  end

  def handle_info(:tick, state) do
    Logger.info("Checking HTTP Monitor")
    case check_http(state.url, [
      verify_ssl: state.verify_ssl,
      follow_redirects: state.follow_redirects,
      check_certificate: state.check_certificate,
      expiry_warn_after: state.expiry_warn_after,
      expiry_critical_after: state.expiry_critical_after
    ]) do
      {:ok, response} ->
        Logger.info("HTTP Monitor OK")
        tick(state.interval)
        if (state.remaining_retries > 1) and (state.status != :ok) do
          {:noreply, %HTTPMonitor{
            state | status: :pending,
            last_checked: DateTime.utc_now(),
            last_status: response.status_code,
            last_error: nil,
            remaining_retries: state.remaining_retries - 1
          }}
        else
          if state.status == :pending do
            Logger.info("UP Alert goes here")
          end
          {:noreply, %HTTPMonitor{
            state | status: :ok,
            last_checked: DateTime.utc_now(),
            last_status: response.status_code,
            last_error: nil,
            remaining_retries: state.retries
          }}
        end
      {:error, error} ->
        Logger.error("HTTP Monitor Error: #{inspect(error)}")
        tick(state.interval)
        if (state.remaining_retries > 1) and (state.status != :error) do
          {:noreply, %HTTPMonitor{
            state | status: :pending,
            last_checked: DateTime.utc_now(),
            last_status: nil,
            last_error: error,
            remaining_retries: state.remaining_retries - 1
          }}
        else
          if state.status == :pending do
            Logger.info("DOWN Alert goes here")
          end
          {:noreply, %HTTPMonitor{
            state | status: :error,
            last_checked: DateTime.utc_now(),
            last_status: nil,
            last_error: error,
            remaining_retries: state.retries
          }}
        end
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  defp check_ssl_expiry(url) do
    # Borrowed from:
    # https://elixirforum.com/t/get-ssl-expiry-date-from-an-http-request-using-mint-finch-mojito/35055/3
    uri = URI.parse(url)

    sslopts = [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        versions: [:"tlsv1.2"]
    ]

    cert =
      with {:ok, sock} <- :ssl.connect(uri.host, uri.port, sslopts),
           {:ok, der} <- :ssl.peercert(sock) do
        :public_key.pkix_decode_cert(der, :plain)
      end

    validity =
      cert
      |> elem(1)
      |> elem(5)

    case validity do
      {:Validity, {:utcTime, valid_from}, {:utcTime, valid_to}} ->
        {:ok, from_cert_time(valid_from), from_cert_time(valid_to)}

      smth ->
        {:error, smth}
    end
  end

  defp from_cert_time(cert_time_charlist) do
    case to_string(cert_time_charlist) do
      <<year::binary-2, month::binary-2, day::binary-2, hour::binary-2, minute::binary-2, second::binary-2, tz::binary>> ->
        DateTime.from_iso8601("20#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}#{tz}")
      _ ->
        {:error, "Invalid time format"}
    end
  end

  defp check_http(url, opts) do
    verify_ssl = case Keyword.get(opts, :verify_ssl, true) do
      true -> :verify_peer
      false -> :verify_none
    end
    case HTTPoison.get(url, [{"User-Agent", "Sentinelix HTTP Monitor"}], [ssl: [verify: verify_ssl]]) do
      {:ok, response} ->
        normalized_headers = Enum.map(response.headers, fn {k, v} -> {String.downcase(k), v} end)
        case response.status_code do
          x when x in 200..299 ->
            {:ok, response}
          x when x in 300..399 ->
            follow_redirects = Keyword.get(opts, :follow_redirects, false)
            if follow_redirects do
              redirects = Keyword.get(opts, :redirects, 0)
              if redirects > 10 do
                {:error, "Too many redirects"}
              else
                case List.keyfind(normalized_headers, "location", 0) do
                  {"location", url} ->
                    Keyword.put(opts, :redirects, redirects + 1)
                    check_http(url, opts)
                  _ ->
                    {:error, "No location header"}
                end
              end
            else
              {:error, response}
            end
          x when x in 400..499 ->
            {:error, response}
          x when x in 500..599 ->
            {:error, response}
          _ ->
            {:error, response}
        end
      {:error, error} ->
        {:error, error}
    end
  end

  defp tick(interval), do: Process.send_after(self(), :tick, :timer.seconds(interval))
end
