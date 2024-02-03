defmodule Sentinelix.Monitors.HTTPMonitor do
  use GenServer
  require Logger

  alias Sentinelix.Monitors.HTTPMonitor

  @moduledoc """
  HTTP Monitor
  """

  defstruct [:name, :url, :status, :interval, :retries,
             :last_checked, :last_status, :last_error,
             :verify_ssl, :follow_redirects, :remaining_retries,
             :last_response_time]

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
              remaining_retries: retries
            }}
      else
        {:error, error} ->
          {:stop, {:error, error}}
        {:name, false} ->
          {:stop, {:error, "Name must be a string"}}
      end
  end

  def handle_info(:tick, state) do
    Logger.info("Checking HTTP Monitor")
    case check_http(state.url, [
      verify_ssl: state.verify_ssl,
      follow_redirects: state.follow_redirects
    ]) do
      {:ok, response, response_time} ->
        Logger.info("HTTP Monitor OK")
        tick(state.interval)
        if (state.remaining_retries > 1) and (state.status != :ok) do
          {:noreply, %HTTPMonitor{
            state | status: :pending,
            last_checked: DateTime.utc_now(),
            last_status: response.status_code,
            last_error: nil,
            remaining_retries: state.remaining_retries - 1,
            last_response_time: response_time
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
            remaining_retries: state.retries,
            last_response_time: response_time
          }}
        end
      {:error, error, response_time} ->
        Logger.error("HTTP Monitor Error: #{inspect(error)}")
        tick(state.interval)
        if (state.remaining_retries > 1) and (state.status != :error) do
          {:noreply, %HTTPMonitor{
            state | status: :pending,
            last_checked: DateTime.utc_now(),
            last_status: nil,
            last_error: error,
            remaining_retries: state.remaining_retries - 1,
            last_response_time: response_time
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
            remaining_retries: state.retries,
            last_response_time: response_time
          }}
        end
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  defp check_http(url, opts) do
    verify_ssl = case Keyword.get(opts, :verify_ssl, true) do
      true -> :verify_peer
      false -> :verify_none
    end
    {response_time, httpoison_result} = :timer.tc(fn ->
      HTTPoison.get(url, [{"User-Agent", "Sentinelix HTTP Monitor"}], [ssl: [verify: verify_ssl]])
    end)
    case httpoison_result do
      {:ok, response} ->
        normalized_headers = Enum.map(response.headers, fn {k, v} -> {String.downcase(k), v} end)
        case response.status_code do
          x when x in 200..299 ->
            {:ok, response, response_time}
          x when x in 300..399 ->
            follow_redirects = Keyword.get(opts, :follow_redirects, false)
            if follow_redirects do
              redirects = Keyword.get(opts, :redirects, 0)
              if redirects > 10 do
                {:error, "Too many redirects", response_time}
              else
                case List.keyfind(normalized_headers, "location", 0) do
                  {"location", url} ->
                    Keyword.put(opts, :redirects, redirects + 1)
                    check_http(url, opts)
                  _ ->
                    {:error, "No location header", response_time}
                end
              end
            else
              {:error, response, response_time}
            end
          x when x in 400..499 ->
            {:error, response, response_time}
          x when x in 500..599 ->
            {:error, response, response_time}
          _ ->
            {:error, response, response_time}
        end
      {:error, error} ->
        {:error, error, response_time}
    end
  end

  defp tick(interval), do: Process.send_after(self(), :tick, :timer.seconds(interval))
end
