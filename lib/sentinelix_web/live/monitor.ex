defmodule SentinelixWeb.Live.Monitor do
  use SentinelixWeb, :live_view
  use SentinelixWeb, :verified_routes
  alias Phoenix.PubSub
  require Logger

  def render(assigns) do
    ~H"""
    <div class="bg-gray-100">
      <% monitor = Map.get(@monitors, "http") %>
      <div class="p-4 bg-white shadow-md rounded-lg mb-4">
        <h2 class="text-lg font-bold">{@name} (http)</h2>
      </div>
      <div id="area-simple" phx-hook="Chart" class="w-[850px]">
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
    socket = assign(socket, monitors: monitors, chart: chart)
    {:noreply, socket}
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

    {:ok, assign(socket, name: params["name"], monitors: monitors, chart: chart)}
  end
end
