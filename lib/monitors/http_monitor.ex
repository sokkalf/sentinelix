defmodule Sentinelix.Monitors.HTTPMonitor do
  use GenServer
  require Logger
  require HTTPoison
  require Jason
  require Finch
  require Telemetry.Metrics

  alias Sentinelix.Monitors.HTTPMonitor

  @moduledoc """
  HTTP Monitor
  """

  @doc """
  Starts the HTTP Monitor
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    Logger.info("Starting HTTP Monitor")
    {:ok, opts}
  end

  def check_http(url, opts \\ []) do
    case HTTPoison.get(url) do
      {:ok, response} ->
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
                case List.keyfind(response.headers, "location", 0) do
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
end
