defmodule SentinelixWeb.MonitorLive.Show do
  @moduledoc """
  Monitor detail page: current status, heartbeats, uptime, a response time
  chart with selectable range, incidents, dependencies (the parent and the
  dependents), the notification channels (attached or routed by selector,
  with a test send to them) and the monitor's runtime state.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents

  alias Sentinelix.{Maintenance, Monitoring, Notifications}
  alias Sentinelix.Monitoring.History
  alias Sentinelix.Notifications.Delivery
  alias Sentinelix.Stats

  @heartbeats 100
  @incidents 25
  @tick_ms 5_000

  # range => {label, seconds, source}: every raw result (:raw) or the
  # hourly statistics (:hourly)
  @ranges [
    {"1h", {"1 hour", 3_600, :raw}},
    {"24h", {"24 hours", 86_400, :raw}},
    {"7d", {"7 days", 7 * 86_400, :hourly}},
    {"30d", {"30 days", 30 * 86_400, :hourly}}
  ]
  # Uptime cards: {key, window, label}
  @uptime_windows [
    {"24h", {24, :hour}, "24 hours"},
    {"7d", {7, :day}, "7 days"},
    {"30d", {30, :day}, "30 days"},
    {"90d", {90, :day}, "90 days"}
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
            <.maintenance_badge id="monitor-maintenance" windows={@maintenance} class="badge-md" />
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
            <.label_badges
              labels={@monitor.labels}
              automatic={@monitor.auto_labels}
              class="badge-sm"
            />
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
          <.link
            id="clone-monitor"
            navigate={~p"/monitors/#{@monitor.id}/clone"}
            class="btn btn-sm"
          >
            <.icon name="hero-document-duplicate" class="size-4" /> Clone
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
        <p
          :if={@status == :unreachable}
          id="unreachable-notice"
          class="mt-2 flex items-center gap-2 text-sm text-base-content/70"
        >
          <.icon name="hero-link-slash-micro" class="size-4" />
          <span :if={@parent}>
            {@parent.monitor.name} is down: this monitor's failures don't alert until it is back.
          </span>
          <span :if={!@parent}>The monitor it depends on was down.</span>
        </p>
      </div>

      <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.stat_card title="Response" id="stat-response">
          {format_ms(@latest && @latest.response_time_ms)}
          <:desc>Latest check</:desc>
        </.stat_card>
        <.stat_card title="Avg. response" id="stat-avg-response">
          {format_ms(@stats_24h.avg_ms)}
          <:desc>24 hours</:desc>
        </.stat_card>
        <.stat_card title="P95 response" id="stat-p95-response">
          {format_ms(@stats_24h.p95_ms)}
          <:desc>24 hours</:desc>
        </.stat_card>
        <.stat_card title="Min / max response" id="stat-min-max-response">
          <span class="text-lg">
            {format_ms(@stats_24h.min_ms)} / {format_ms(@stats_24h.max_ms)}
          </span>
          <:desc>24 hours</:desc>
        </.stat_card>
        <.stat_card
          :for={{key, label, uptime} <- @uptimes}
          title="Uptime"
          id={"stat-uptime-#{key}"}
        >
          {format_uptime(uptime)}
          <:desc>{label}</:desc>
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

        <div class="space-y-4">
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

          <div id="dependencies" class="rounded-box border border-base-300 bg-base-100 p-4">
            <div class="mb-2 text-sm font-medium">Dependencies</div>
            <dl class="space-y-2 text-sm">
              <dt class="text-base-content/60">Depends on</dt>
              <dd id="parent">
                <div :if={@parent} class="flex items-center justify-between gap-2">
                  <.link navigate={~p"/monitors/#{@parent.monitor}"} class="truncate hover:underline">
                    {@parent.monitor.name}
                  </.link>
                  <.status_badge status={@parent.status} />
                </div>
                <span :if={!@parent} class="text-base-content/60">Nothing</span>
              </dd>
              <dt class="text-base-content/60">Dependents</dt>
              <dd id="children">
                <span :if={@children == []} class="text-base-content/60">None</span>
                <ul :if={@children != []} class="space-y-1">
                  <li
                    :for={child <- @children}
                    id={"child-#{child.monitor.id}"}
                    class="flex items-center justify-between gap-2"
                  >
                    <.link navigate={~p"/monitors/#{child.monitor}"} class="truncate hover:underline">
                      {child.monitor.name}
                    </.link>
                    <.status_badge status={child.status} />
                  </li>
                </ul>
              </dd>
            </dl>
            <p class="mt-3 text-xs text-base-content/60">
              While the monitor this one depends on is down, failed checks are recorded as
              unreachable and don't alert.
            </p>
          </div>

          <div id="notifications" class="rounded-box border border-base-300 bg-base-100 p-4">
            <div class="mb-2 flex items-center justify-between gap-2">
              <span class="text-sm font-medium">Notifications</span>
              <button
                id="send-test-notification"
                type="button"
                phx-click="send_test"
                class="btn btn-xs"
                disabled={@testing or not Enum.any?(@channels, fn {c, _} -> c.enabled end)}
                title="Send a test notification to the enabled channels below"
              >
                <.icon name="hero-paper-airplane" class="size-3" /> Send test
              </button>
            </div>
            <p :if={@channels == []} id="no-channels" class="text-sm text-base-content/60">
              No channels notify this monitor.
            </p>
            <ul :if={@channels != []} id="monitor-channels" class="space-y-1 text-sm">
              <li
                :for={{channel, reasons} <- @channels}
                id={"monitor-channel-#{channel.id}"}
                class="flex flex-wrap items-center gap-1"
              >
                <span class={["truncate", !channel.enabled && "text-base-content/50"]}>
                  {channel.name}
                </span>
                <span
                  :if={:explicit in reasons}
                  class="badge badge-ghost badge-xs"
                  title="Attached to this monitor"
                >
                  attached
                </span>
                <span
                  :if={:selector in reasons}
                  class="badge badge-info badge-soft badge-xs"
                  title="Its selector matches this monitor"
                >
                  via selector <code>{channel.selector}</code>
                </span>
                <span :if={!channel.enabled} class="badge badge-warning badge-soft badge-xs">
                  disabled
                </span>
              </li>
            </ul>
          </div>
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
          Maintenance.subscribe()
          Notifications.subscribe_channels()
          schedule_tick()
        end

        socket =
          socket
          |> assign(monitor: monitor, page_title: monitor.name, now: DateTime.utc_now())
          |> assign(testing: false)
          |> assign_channels()
          |> assign(heartbeats: Monitoring.latest_results(monitor, @heartbeats) |> Enum.reverse())
          |> assign_latest()
          |> assign_worker()
          |> assign_maintenance()
          |> assign_dependencies()
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

  def handle_event("send_test", _params, socket) do
    monitor = socket.assigns.monitor

    {:noreply,
     socket
     |> assign(testing: true)
     |> start_async(:test_notification, fn ->
       Notifications.send_monitor_test_notification(monitor)
     end)}
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
  def handle_async(:test_notification, {:ok, results}, socket) do
    {sent, failed} = Enum.split_with(results, &match?({_channel, :ok}, &1))

    socket =
      cond do
        results == [] ->
          put_flash(socket, :error, "No enabled channel notifies this monitor.")

        failed == [] ->
          put_flash(socket, :info, "Test notification sent to #{channel_names(sent)}.")

        true ->
          errors =
            Enum.map_join(failed, "; ", fn {channel, {:error, reason}} ->
              "#{channel.name}: #{Delivery.format_error(reason)}"
            end)

          sent_text = if sent == [], do: "", else: " Sent to #{channel_names(sent)}."
          put_flash(socket, :error, "Test notification failed for #{errors}.#{sent_text}")
      end

    {:noreply, socket |> assign(testing: false) |> assign_channels()}
  end

  def handle_async(:test_notification, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(testing: false)
     |> put_flash(:error, "Test notification failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({:check_result, result}, socket) do
    heartbeats = Enum.take(socket.assigns.heartbeats ++ [result], -@heartbeats)

    socket =
      socket
      |> assign(heartbeats: heartbeats, now: DateTime.utc_now())
      |> assign_latest()
      |> assign_worker()
      |> assign_dependencies()
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
     |> assign_worker()
     |> assign_dependencies()
     |> assign_channels()}
  end

  def handle_info({event, _channel}, socket)
      when event in [:channel_created, :channel_updated, :channel_deleted],
      do: {:noreply, assign_channels(socket)}

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

  def handle_info({:maintenance_changed}, socket), do: {:noreply, assign_maintenance(socket)}

  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, socket |> assign(now: DateTime.utc_now()) |> assign_worker()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Data

  # The channels that notify the monitor and why (attached, via selector),
  # as the dispatcher resolves them, disabled ones included. Reloaded when
  # channels or the monitor change.
  defp assign_channels(socket) do
    assign(socket, channels: Notifications.list_routed_channels(socket.assigns.monitor))
  end

  defp channel_names(results),
    do: Enum.map_join(results, ", ", fn {channel, _} -> channel.name end)

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

  defp assign_maintenance(socket) do
    id = socket.assigns.monitor.id
    assign(socket, maintenance: Map.get(Maintenance.active_windows_for([id]), id, []))
  end

  # The parent and the children with their current status. Not live: they
  # are refreshed with every check result of this monitor (which follows
  # its parent's recovery) and when it is updated.
  defp assign_dependencies(socket) do
    monitor = socket.assigns.monitor
    parent = monitor.parent_id && Monitoring.get_monitor(monitor.parent_id)
    children = Monitoring.list_children(monitor)
    monitors = Enum.reject([parent | children], &is_nil/1)
    latest = History.recent_results_by_monitor(1, Enum.map(monitors, & &1.id))

    with_status = fn monitor ->
      %{
        monitor: monitor,
        status: display_status(monitor, latest |> Map.get(monitor.id, []) |> List.last())
      }
    end

    assign(socket,
      parent: parent && with_status.(parent),
      children: Enum.map(children, with_status)
    )
  end

  defp assign_stats(socket) do
    monitor = socket.assigns.monitor
    now = DateTime.utc_now()
    stats_24h = Stats.summary(monitor, {24, :hour}, now: now)

    uptimes =
      Enum.map(@uptime_windows, fn
        {"24h", _window, label} -> {"24h", label, stats_24h.uptime}
        {key, window, label} -> {key, label, Stats.uptime(monitor, window, now: now)}
      end)

    assign(socket, stats_24h: stats_24h, uptimes: uptimes)
  end

  defp assign_chart(socket) do
    {_label, seconds, source} = range_spec(socket.assigns.range)
    points = chart_points(socket.assigns.monitor, seconds, source)

    assign(socket,
      chart_points: Jason.encode!(Enum.map(points, &chart_point/1)),
      chart_empty: points == [],
      chart_live: source == :raw,
      range_ms: seconds * 1000
    )
  end

  defp chart_points(monitor, seconds, :raw) do
    History.response_times(monitor, DateTime.add(DateTime.utc_now(), -seconds, :second))
  end

  # One point per hour: the average response time of the hour's up checks,
  # marked down if any check in it was down. Maintenance-only hours are
  # left out.
  defp chart_points(monitor, seconds, :hourly) do
    monitor
    |> Stats.hourly({div(seconds, 3_600), :hour})
    |> Enum.reject(&(&1.up + &1.down + &1.pending + &1.unreachable == 0))
    |> Enum.map(fn hour ->
      %{
        at: hour.hour,
        response_time_ms: hour.avg_ms && round(hour.avg_ms),
        down: hour.down + hour.unreachable > 0
      }
    end)
  end

  defp push_chart_point(%{assigns: %{chart_live: true}} = socket, %{status: status} = result)
       when status != :maintenance do
    point =
      chart_point(%{
        at: result.checked_at,
        response_time_ms: result.response_time_ms,
        down: status in [:down, :unreachable]
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
