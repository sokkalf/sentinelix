defmodule SentinelixWeb.Live.Dashboard do
  use SentinelixWeb, :live_view
  use SentinelixWeb, :verified_routes
  alias Phoenix.PubSub
  require Logger

  def render(assigns) do
    ~H"""
    <div class="bg-gray-100">
      <%= for {{name, type}, monitor} <- @monitors do %>
        <div class="p-4 bg-white shadow-md rounded-lg mb-4">
          <h2 class="text-lg font-bold"><%= name %> (<%= type %>)</h2>
          <p class="text-sm text-gray-600">Status: <%= monitor.status %></p>
          <p class="text-sm text-gray-600">Last checked: <%= monitor.last_checked %></p>
          <p class="text-sm text-gray-600">Last status: <%= monitor.last_status %></p>
          <p class="text-sm text-gray-600">Last error: <%= monitor.last_error %></p>
          <p class="text-sm text-gray-600">Last response time: <%= monitor.last_response_time %></p>
        </div>
      <% end %>
      <div id="pie" phx-hook="Chart">
        <div id="pie-chart" style="width: 400px; height: 400px;" phx-update="ignore"></div>
        <div id="pie-data" hidden><%= Jason.encode!(@chart) %></div>
    </div>
    </div>
    """
  end

  def handle_info({monitor_name, monitor_type, monitor_data}, socket) do
    Logger.debug("Received monitor data")
    socket = assign(socket, monitors: Map.put(socket.assigns.monitors, {monitor_name, monitor_type}, monitor_data))
    {:noreply, socket}
  end

  def mount(_params, _session, socket) do
    PubSub.subscribe(Sentinelix.PubSub, "MonitorUpdate")

      chart = %{
      title: %{text: "π", left: "center", top: "center"},
      series: [
        %{
          type: "pie",
          data: [
            %{name: "A", value: 20},
            %{name: "B", value: 50},
            %{name: "C", value: 100}
          ],
          radius: ["40%", "70%"]
        }
      ]
    }

    monitors = %{}
    {:ok, assign(socket, monitors: monitors, chart: chart)}
  end
end
