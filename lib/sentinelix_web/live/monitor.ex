defmodule SentinelixWeb.Live.Monitor do
  @moduledoc """
  Minimal monitor page: latest status and a response time chart.
  (The full UI is a separate issue.)
  """

  use SentinelixWeb, :live_view

  alias Sentinelix.Monitoring

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-4">
        <div class="card bg-base-200 p-4">
          <h2 class="text-lg font-bold">{@monitor.name} ({@monitor.type})</h2>
          <p class="text-sm">Target: {target(@monitor)}</p>
          <%= if result = List.first(@results) do %>
            <p class="text-sm">Status: {result.status}</p>
            <p class="text-sm">Last checked: {result.checked_at}</p>
            <p class="text-sm">Message: {result.message}</p>
          <% else %>
            <p class="text-sm">No checks yet.</p>
          <% end %>
          <p :if={avg = avg_response_time(@results)} class="text-sm">
            Average response time: {avg} ms
          </p>
        </div>
        <div id="response-time" phx-hook="Chart" class="w-full">
          <div id="response-time-chart" style="height: 400px;" phx-update="ignore"></div>
          <div id="response-time-data" hidden>{Jason.encode!(@chart)}</div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def mount(%{"id" => id}, _session, socket) do
    with {id, ""} <- Integer.parse(id),
         %{} = monitor <- Monitoring.get_monitor(id) do
      if connected?(socket), do: Monitoring.subscribe_monitor(monitor)
      {:ok, socket |> assign(monitor: monitor) |> load_results()}
    else
      _ ->
        {:ok, socket |> put_flash(:error, "Monitor not found") |> push_navigate(to: ~p"/")}
    end
  end

  def handle_info({:check_result, _result}, socket), do: {:noreply, load_results(socket)}

  def handle_info({:monitor_updated, monitor}, socket),
    do: {:noreply, assign(socket, monitor: monitor)}

  def handle_info({:monitor_deleted, _monitor}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/")}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_results(socket) do
    results = Monitoring.latest_results(socket.assigns.monitor, 50)
    assign(socket, results: results, chart: chart_data(Enum.reverse(results)))
  end

  defp target(%{settings: %{url: url}}) when is_binary(url), do: url

  defp target(%{settings: %{host: host, port: port}}) when is_binary(host) and is_integer(port),
    do: "#{host}:#{port}"

  defp target(%{settings: %{host: host}}) when is_binary(host), do: host
  defp target(_monitor), do: "-"

  defp avg_response_time(results) do
    case Enum.reject(results, &is_nil(&1.response_time_ms)) do
      [] -> nil
      timed -> div(Enum.sum_by(timed, & &1.response_time_ms), length(timed))
    end
  end

  defp chart_data(results) do
    %{
      xAxis: %{
        type: "category",
        boundaryGap: false,
        data: Enum.map(results, &Calendar.strftime(&1.checked_at, "%H:%M:%S"))
      },
      yAxis: %{type: "value", axisLabel: %{formatter: "{value} ms"}},
      tooltip: %{trigger: "axis", formatter: "{b0}: {c0} ms"},
      series: [
        %{
          data: Enum.map(results, & &1.response_time_ms),
          type: "line",
          showSymbol: false,
          areaStyle: %{}
        }
      ]
    }
  end
end
