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
      <div id="area-simple" phx-hook="Chart">
        <div id="area-simple-chart" style="width: 1024px; height: 400px;" phx-update="ignore"></div>
        <div id="area-simple-data" hidden>{Jason.encode!(@chart)}</div>
      </div>
    </div>
    """
  end

  def handle_info(:updated, socket) do
    monitors = SentinelixWeb.Services.MonitorService.list_all_monitors()
    IO.inspect(monitors)
    Logger.debug("Received monitor data")
    #socket = assign(socket, monitors: monitors)
    {:noreply, socket}
  end

  def mount(params, _session, socket) do
    types = Cachex.get(:monitor_cache, params["name"])

    monitors =
      case types do
        {:ok, nil} ->
          %{}

        {:ok, types} ->
          Enum.reduce(types, %{}, fn type, acc ->
            Map.put(
              acc,
              type,
              SentinelixWeb.Services.MonitorService.get_monitor_data(params["name"], type, 50)
              |> Enum.reverse()
            )
          end)
      end

    IO.inspect(monitors)
    PubSub.subscribe(Sentinelix.PubSub, "WebUpdate")

    chart = %{
      xAxis: %{
        type: "category",
        boundaryGap: false,
        data: monitors["http"] |> Enum.map(&(&1.last_checked))
      },
      yAxis: %{
        type: "value"
      },
      series: [
        %{
          data: monitors["http"] |> Enum.map(&(&1.last_response_time)),
          type: "line",
          areaStyle: %{}
        }
      ]
    }

    {:ok, assign(socket, name: params["name"], monitors: monitors, chart: chart)}
  end
end
