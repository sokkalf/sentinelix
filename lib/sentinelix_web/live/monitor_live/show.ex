defmodule SentinelixWeb.MonitorLive.Show do
  @moduledoc """
  Monitor detail page: current status, heartbeats, uptime, a response time
  chart with selectable range, incidents and the monitor's runtime state.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.History

  @heartbeats 100
  @incidents 25
  @tick_ms 5_000

  # range => {label, seconds, bucket seconds (nil = raw results)}
  @ranges [
    {"1h", {"1 hour", 3_600, nil}},
    {"24h", {"24 hours", 86_400, nil}},
    {"7d", {"7 days", 7 * 86_400, 600}},
    {"30d", {"30 days", 30 * 86_400, 3_600}}
  ]
  @range_keys Enum.map(@ranges, &elem(&1, 0))
  @default_range "24h"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:monitors}>
      <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div class="min-w-0">
          <.link navigate={~p"/monitors"} class="text-sm text-base-content/60 hover:underline">
            <.icon name="hero-arrow-left-micro" class="size-4" /> Monitors
          </.link>
          <div class="mt-1 flex flex-wrap items-center gap-3">
            <h1 id="monitor-name" class="truncate text-2xl font-semibold">{@monitor.name}</h1>
            <.status_badge id="monitor-status" status={@status} class="badge-md" />
            <span
              :if={@worker && @worker.warning}
              id="monitor-warning"
              class="badge badge-warning badge-md gap-1"
            >
              <.icon name="hero-exclamation-triangle-micro" class="size-4" /> Warning
            </span>
          </div>
          <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-base-content/60">
            <span>{type_label(@monitor.type)}</span>
            <span :if={target(@monitor)}>·</span>
            <a
              :if={@monitor.settings && @monitor.settings.url}
              href={@monitor.settings.url}
              target="_blank"
              rel="noopener noreferrer"
              class="link link-hover break-all"
            >
              {target(@monitor)}
            </a>
            <span
              :if={!(@monitor.settings && @monitor.settings.url) && target(@monitor)}
              class="break-all"
            >
              {target(@monitor)}
            </span>
            <span :for={tag <- @monitor.tags} class="badge badge-ghost badge-sm">{tag}</span>
          </div>
          <p :if={@monitor.description} class="mt-2 max-w-prose text-sm">{@monitor.description}</p>
        </div>

        <div class="flex flex-wrap gap-2">
          <button
            :if={@monitor.type != :push}
            id="check-now"
            type="button"
            phx-click="check_now"
            class="btn btn-sm"
            disabled={!@monitor.enabled}
          >
            <.icon
              name="hero-arrow-path"
              class={["size-4", @worker && @worker.checking && "animate-spin"]}
            /> Check now
          </button>
          <button id="toggle-monitor" type="button" phx-click="toggle" class="btn btn-sm">
            <%= if @monitor.enabled do %>
              <.icon name="hero-pause" class="size-4" /> Pause
            <% else %>
              <.icon name="hero-play" class="size-4" /> Resume
            <% end %>
          </button>
          <.link id="edit-monitor" navigate={~p"/monitors/#{@monitor.id}/edit"} class="btn btn-sm">
            <.icon name="hero-pencil-square" class="size-4" /> Edit
          </.link>
          <button
            id="delete-monitor"
            type="button"
            phx-click="delete"
            data-confirm={"Delete #{@monitor.name} and all of its history?"}
            class="btn btn-sm btn-error btn-soft"
          >
            <.icon name="hero-trash" class="size-4" /> Delete
          </button>
        </div>
      </div>

      <div
        :if={@monitor.type == :push}
        id="push-url"
        class="rounded-box border border-info/30 bg-info/5 p-4"
      >
        <div class="text-sm font-medium">Push URL</div>
        <p class="text-xs text-base-content/60">
          Send a GET or POST request to this URL at least every {format_duration(
            @monitor.interval_seconds
          )}.
          Optional query parameters: <code>status=up|down</code>, <code>msg=...</code>, <code>ping=ms</code>.
        </p>
        <div class="join mt-2 w-full">
          <input
            id="push-url-value"
            type="text"
            readonly
            value={push_url(@monitor.settings && @monitor.settings.push_token)}
            class="input input-sm join-item w-full font-mono"
          />
          <button
            id="copy-push-url"
            type="button"
            class="btn btn-sm join-item"
            phx-hook="CopyToClipboard"
            data-target="push-url-value"
          >
            <.icon name="hero-clipboard-document" class="size-4" /> Copy
          </button>
        </div>
        <pre
          id="push-curl"
          class="mt-2 overflow-x-auto rounded-field bg-base-200 p-2 text-xs"
        ><code>curl -fsS "{push_url(@monitor.settings && @monitor.settings.push_token)}?status=up&amp;msg=OK"</code></pre>
        <p class="mt-1 text-xs text-base-content/60">
          Grace period: {format_duration(@monitor.settings.push_grace_seconds || 0)}.
          A new token can be generated when editing the monitor.
        </p>
      </div>

      <div class="rounded-box border border-base-300 bg-base-100 p-4">
        <div class="mb-3 flex flex-wrap items-center justify-between gap-2 text-sm">
          <span class="font-medium">Recent checks</span>
          <span id="next-check" class="text-base-content/60">
            {next_check_text(@monitor, @worker, @now)}
          </span>
        </div>
        <.heartbeat_bar id="heartbeats" results={@heartbeats} slots={heartbeat_slots()} size="md" />
        <p :if={@heartbeats == []} id="no-checks" class="mt-3 text-sm text-base-content/60">
          No checks yet.
        </p>
        <p
          :if={@latest && @latest.message}
          id="latest-message"
          class={["mt-3 text-sm", status_text_class(@latest.status)]}
        >
          {@latest.message}
        </p>
      </div>

      <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.stat_card title="Response" id="stat-response">
          {format_ms(@latest && @latest.response_time_ms)}
          <:desc>Latest check</:desc>
        </.stat_card>
        <.stat_card title="Avg. response" id="stat-avg-response">
          {format_ms(@avg_24h)}
          <:desc>24 hours</:desc>
        </.stat_card>
        <.stat_card title="Uptime" id="stat-uptime-24h">
          {format_uptime(@uptime_24h)}
          <:desc>24 hours</:desc>
        </.stat_card>
        <.stat_card title="Uptime" id="stat-uptime-30d">
          {format_uptime(@uptime_30d)}
          <:desc>30 days</:desc>
        </.stat_card>
      </div>

      <div
        :if={@monitor.type == :cert}
        id="cert-info"
        class="rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="flex items-center gap-2 text-sm font-medium">
          <.icon name="hero-lock-closed" class="size-4" /> Certificate
        </div>
        <p class={["mt-1 text-sm", @latest && status_text_class(@latest.status)]}>
          {(@latest && @latest.message) || "Not checked yet."}
        </p>
        <p class="mt-1 text-xs text-base-content/60">
          Warning below {@monitor.settings.cert_warn_days} days, down below {@monitor.settings.cert_critical_days} days.
        </p>
      </div>

      <div class="rounded-box border border-base-300 bg-base-100 p-4">
        <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
          <span class="text-sm font-medium">Response time</span>
          <div class="join" id="range-selector">
            <.link
              :for={{key, {label, _seconds, _bucket}} <- ranges()}
              patch={~p"/monitors/#{@monitor.id}?#{[range: key]}"}
              class={["btn btn-xs join-item", @range == key && "btn-active btn-primary"]}
              title={label}
              id={"range-#{key}"}
            >
              {key}
            </.link>
          </div>
        </div>
        <div
          id="response-chart"
          phx-hook="ResponseChart"
          data-points={@chart_points}
          data-range-ms={@range_ms}
          data-live={to_string(@chart_live)}
          class="relative h-64 w-full sm:h-72"
        >
          <div id="response-chart-canvas" phx-update="ignore" class="absolute inset-0"></div>
        </div>
        <p :if={@chart_empty} id="chart-empty" class="text-center text-sm text-base-content/60">
          No response times in this period.
        </p>
      </div>

      <div class="grid gap-4 lg:grid-cols-3">
        <div class="rounded-box border border-base-300 bg-base-100 lg:col-span-2">
          <div class="border-b border-base-300 px-4 py-3 text-sm font-medium">Incidents</div>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Status</th>
                  <th>Started</th>
                  <th>Duration</th>
                  <th class="hidden sm:table-cell">Message</th>
                </tr>
              </thead>
              <tbody id="incidents" phx-update="stream">
                <tr id="incidents-empty" class="hidden only:table-row">
                  <td colspan="4" class="py-6 text-center text-base-content/60">
                    No incidents. <.icon name="hero-sparkles-micro" class="size-4" />
                  </td>
                </tr>
                <tr :for={{dom_id, incident} <- @streams.incidents} id={dom_id}>
                  <td>
                    <span :if={incident.resolved_at} class="badge badge-success badge-soft badge-sm">Resolved</span>
                    <span :if={!incident.resolved_at} class="badge badge-error badge-sm">Ongoing</span>
                  </td>
                  <td class="whitespace-nowrap">
                    <.local_time id={"#{dom_id}-started"} at={incident.started_at} />
                  </td>
                  <td class="whitespace-nowrap tabular-nums">{incident_duration(incident)}</td>
                  <td
                    class="hidden max-w-sm truncate text-base-content/70 sm:table-cell"
                    title={incident.message}
                  >
                    {incident.message}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <div class="mb-2 text-sm font-medium">Configuration</div>
          <dl id="monitor-config" class="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
            <dt class="text-base-content/60">Interval</dt>
            <dd>{format_duration(@monitor.interval_seconds)}</dd>
            <dt class="text-base-content/60">Retry interval</dt>
            <dd>{format_duration(@monitor.retry_interval_seconds)}</dd>
            <dt class="text-base-content/60">Retries</dt>
            <dd>
              {if @worker,
                do: "#{@worker.retries} / #{@monitor.max_retries}",
                else: @monitor.max_retries}
            </dd>
            <dt class="text-base-content/60">Timeout</dt>
            <dd>{format_ms(@monitor.timeout_ms)}</dd>
            <dt class="text-base-content/60">Last check</dt>
            <dd>
              <.local_time id="last-check" at={@latest && @latest.checked_at} />
            </dd>
            <dt class="text-base-content/60">Created</dt>
            <dd><.local_time id="created-at" at={@monitor.inserted_at} /></dd>
          </dl>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case get_monitor(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Monitor not found.")
         |> push_navigate(to: ~p"/monitors")}

      monitor ->
        if connected?(socket) do
          Monitoring.subscribe_monitor(monitor)
          schedule_tick()
        end

        socket =
          socket
          |> assign(monitor: monitor, page_title: monitor.name, now: DateTime.utc_now())
          |> assign(heartbeats: Monitoring.latest_results(monitor, @heartbeats) |> Enum.reverse())
          |> assign_latest()
          |> assign_worker()
          |> assign_stats()
          |> stream(:incidents, Monitoring.list_incidents(monitor, @incidents))

        {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = if params["range"] in @range_keys, do: params["range"], else: @default_range
    {:noreply, socket |> assign(range: range) |> assign_chart()}
  end

  @impl true
  def handle_event("check_now", _params, socket) do
    case Monitoring.check_now(socket.assigns.monitor) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Check started.") |> assign_worker()}

      {:error, :not_running} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The monitor isn't running (it is paused or its type can't be checked yet)."
         )}
    end
  end

  def handle_event("toggle", _params, socket) do
    case Monitoring.toggle_monitor(socket.assigns.monitor) do
      {:ok, monitor} ->
        verb = if monitor.enabled, do: "resumed", else: "paused"

        {:noreply,
         socket
         |> put_flash(:info, "Monitor #{verb}.")
         |> assign(monitor: monitor)
         |> assign_latest()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update the monitor.")}
    end
  end

  def handle_event("delete", _params, socket) do
    case Monitoring.delete_monitor(socket.assigns.monitor) do
      {:ok, monitor} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{monitor.name} deleted.")
         |> push_navigate(to: ~p"/monitors")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete the monitor.")}
    end
  end

  @impl true
  def handle_info({:check_result, result}, socket) do
    heartbeats = Enum.take(socket.assigns.heartbeats ++ [result], -@heartbeats)

    socket =
      socket
      |> assign(heartbeats: heartbeats, now: DateTime.utc_now())
      |> assign_latest()
      |> assign_worker()
      |> assign_stats()
      |> push_chart_point(result)

    {:noreply, socket}
  end

  def handle_info({event, incident}, socket)
      when event in [:incident_opened, :incident_resolved] do
    at = if event == :incident_opened, do: 0, else: -1
    {:noreply, stream_insert(socket, :incidents, incident, at: at)}
  end

  def handle_info({:monitor_updated, monitor}, socket) do
    {:noreply,
     socket
     |> assign(monitor: monitor, page_title: monitor.name)
     |> assign_latest()
     |> assign_worker()}
  end

  def handle_info({:monitor_deleted, monitor}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "#{monitor.name} was deleted.")
     |> push_navigate(to: ~p"/monitors")}
  end

  def handle_info({event, _monitor, _result}, socket)
      when event in [:warning_raised, :warning_cleared] do
    {:noreply, assign_worker(socket)}
  end

  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, socket |> assign(now: DateTime.utc_now()) |> assign_worker()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Data

  defp get_monitor(id) do
    case Integer.parse(id) do
      {id, ""} -> Monitoring.get_monitor(id)
      _ -> nil
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp assign_latest(socket) do
    latest = List.last(socket.assigns.heartbeats)
    assign(socket, latest: latest, status: display_status(socket.assigns.monitor, latest))
  end

  defp assign_worker(socket) do
    assign(socket, worker: Monitoring.worker_info(socket.assigns.monitor))
  end

  defp assign_stats(socket) do
    monitor = socket.assigns.monitor
    now = DateTime.utc_now()
    day_ago = DateTime.add(now, -1, :day)

    assign(socket,
      uptime_24h: History.uptime(monitor, day_ago),
      uptime_30d: History.uptime(monitor, DateTime.add(now, -30, :day)),
      avg_24h: History.average_response_time(monitor, day_ago)
    )
  end

  defp assign_chart(socket) do
    {_label, seconds, bucket} = range_spec(socket.assigns.range)
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)
    points = History.response_times(socket.assigns.monitor, since, bucket_seconds: bucket)

    assign(socket,
      chart_points: Jason.encode!(Enum.map(points, &chart_point/1)),
      chart_empty: points == [],
      chart_live: bucket == nil,
      range_ms: seconds * 1000
    )
  end

  defp push_chart_point(%{assigns: %{chart_live: true}} = socket, %{status: status} = result)
       when status != :maintenance do
    point =
      chart_point(%{
        at: result.checked_at,
        response_time_ms: result.response_time_ms,
        down: status == :down
      })

    socket
    |> assign(chart_empty: false)
    |> push_event("response-chart:point", %{point: point})
  end

  defp push_chart_point(socket, _result), do: socket

  defp chart_point(%{at: at, response_time_ms: ms, down: down}),
    do: [DateTime.to_unix(at, :millisecond), ms, if(down, do: 1, else: 0)]

  defp ranges, do: @ranges

  defp range_spec(range) do
    {_key, spec} = List.keyfind(@ranges, range, 0)
    spec
  end

  defp heartbeat_slots, do: @heartbeats

  defp next_check_text(%{enabled: false}, _worker, _now), do: "Paused"
  defp next_check_text(_monitor, nil, _now), do: "Not running"
  defp next_check_text(_monitor, %{checking: true}, _now), do: "Checking…"

  defp next_check_text(_monitor, %{next_check_at: %DateTime{} = at} = worker, now) do
    retrying = if worker.retries > 0, do: " (retry #{worker.retries})", else: ""
    "Next check " <> relative_time(at, now) <> retrying
  end

  defp next_check_text(_monitor, _worker, _now), do: ""

  defp incident_duration(%{started_at: started, resolved_at: nil}),
    do: format_duration(DateTime.diff(DateTime.utc_now(), started)) <> " so far"

  defp incident_duration(%{started_at: started, resolved_at: resolved}),
    do: format_duration(DateTime.diff(resolved, started))
end
