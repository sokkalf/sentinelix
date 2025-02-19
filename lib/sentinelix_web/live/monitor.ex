defmodule SentinelixWeb.Live.Monitor do
  use SentinelixWeb, :live_view
  use SentinelixWeb, :verified_routes
  alias Phoenix.PubSub
  require Logger

  def render(assigns) do
    ~H"""
    <div class="bg-gray-100">
      <div class="grid grid-cols-2">
        <div class="p-4 bg-white shadow-md rounded-lg mb-4">
          <h2 class="text-lg font-bold">{@name} (http)</h2>
          <p class="text-sm text-gray-600">URL: {@last_status_http.url}</p>
          <p class="text-sm text-gray-600">Status: {@last_status_http.last_status}</p>
          <p class="text-sm text-gray-600">Last checked: {@last_status_http.last_checked}</p>
          <p class="text-sm text-gray-600">Response: {@last_status_http.last_error}</p>
        </div>
        <div class="p-4 bg-white shadow-md rounded-lg mb-4">
          <%= if Map.get(@monitors, "cert") != nil do %>
            <h2 class="text-lg font-bold">{@name} (cert)</h2>
            <p class="text-sm text-gray-600">URL: {@last_status_cert.url}</p>
            <p class="text-sm text-gray-600">Status: {@last_status_cert.last_status}</p>
            <p class="text-sm text-gray-600">Last checked: {@last_status_cert.last_checked}</p>
            <p class="text-sm text-gray-600">Response: {@last_status_cert.last_error}</p>
          <% end %>
        </div>
      </div>
      <div id="area-simple" phx-hook="Chart" class="w-[1000px]">
        <div id="area-simple-chart" style="height: 400px;" phx-update="ignore"></div>
        <div id="area-simple-data" hidden>{Jason.encode!(@chart)}</div>
      </div>
    </div>
    """
  end

  def handle_info(:updated, socket) do
    monitors = update_data(socket.assigns.name)
    Logger.debug("Received monitor data")
    chart = chart_data(Map.get(monitors, "http"))
    last_status_http = get_last_status(Map.get(monitors, "http"))
    last_status_cert = get_last_status(Map.get(monitors, "cert"))
    socket = assign(socket, monitors: monitors, chart: chart, last_status_http: last_status_http, last_status_cert: last_status_cert)
    {:noreply, socket}
  end

  def get_last_status(monitor) do
    monitor
    |> Enum.reverse()
    |> hd
  end

  def chart_data(nil), do: %{}
  def chart_data(monitor) do
    monitor = monitor
    |> Enum.reject(fn x -> x.last_checked == nil end)

    %{
      xAxis: %{
        type: "category",
        boundaryGap: false,
        data: monitor
        |> Enum.map(fn x ->
          Calendar.strftime(x.last_checked, "%H:%M")
        end)
      },
      yAxis: %{
        type: "value",
        axisLabel: %{
          formatter: "{value} ms"
        }
      },
      tooltip: %{
        trigger: "axis"
      },
      series: [
        %{
          data: monitor
          |> Enum.map(fn x ->
            x.last_response_time / 1000
          end),
          type: "line",
          areaStyle: %{}
        }
      ]
    }
  end

  def update_data(name) do
    types = Cachex.get(:monitor_cache, name)

    case types do
      {:ok, nil} ->
        %{}

      {:ok, types} ->
        Enum.reduce(types, %{}, fn type, acc ->
          Map.put(
            acc,
            type,
            SentinelixWeb.Services.MonitorService.get_monitor_data(name, type, 50)
            |> Enum.reverse()
          )
        end)
    end
  end

  def mount(params, _session, socket) do
    PubSub.subscribe(Sentinelix.PubSub, "WebUpdate")

    monitors = update_data(params["name"])
    chart = chart_data(Map.get(monitors, "http"))
    last_status_http = get_last_status(Map.get(monitors, "http"))
    last_status_cert = get_last_status(Map.get(monitors, "cert"))

    {:ok, assign(socket, name: params["name"], monitors: monitors, chart: chart, last_status_http: last_status_http, last_status_cert: last_status_cert)}
  end
end
