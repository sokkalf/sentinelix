defmodule SentinelixWeb.Live.Dashboard do
  @moduledoc """
  Minimal dashboard listing the monitors and their latest check result.
  (The full UI is a separate issue.)
  """

  use SentinelixWeb, :live_view

  alias Sentinelix.Monitoring

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-4">
        <p :if={@monitors == []} class="text-sm opacity-70">No monitors yet.</p>
        <div :for={monitor <- @monitors} id={"monitor-#{monitor.id}"} class="card bg-base-200 p-4">
          <% result = @latest[monitor.id] %>
          <h2 class="text-lg font-bold">
            <.link navigate={~p"/monitors/#{monitor.id}"}>{monitor.name}</.link>
            <span class="text-sm font-normal opacity-70">({monitor.type})</span>
          </h2>
          <p class="text-sm">
            Status: {status_label(monitor, result)}
          </p>
          <%= if result do %>
            <p class="text-sm">Last checked: {result.checked_at}</p>
            <p class="text-sm">Message: {result.message}</p>
            <p class="text-sm">Response time: {result.response_time_ms} ms</p>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    monitors = Monitoring.list_monitors()

    if connected?(socket) do
      Monitoring.subscribe_monitors()
      Enum.each(monitors, &Monitoring.subscribe_monitor/1)
    end

    {:ok, load(socket, monitors)}
  end

  def handle_info({:monitor_created, monitor}, socket) do
    Monitoring.subscribe_monitor(monitor)
    {:noreply, load(socket)}
  end

  def handle_info({event, _}, socket)
      when event in [:monitor_updated, :monitor_deleted, :check_result] do
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket, monitors \\ Monitoring.list_monitors()) do
    assign(socket, monitors: monitors, latest: Monitoring.latest_result_per_monitor())
  end

  defp status_label(%{enabled: false}, _result), do: "paused"
  defp status_label(_monitor, nil), do: "pending"
  defp status_label(_monitor, result), do: result.status
end
