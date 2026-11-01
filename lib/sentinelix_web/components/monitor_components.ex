defmodule SentinelixWeb.MonitorComponents do
  @moduledoc """
  Components and formatting helpers for monitors: status and label badges,
  heartbeat bars, uptime and response time values.
  """

  use SentinelixWeb, :html

  alias Sentinelix.Monitoring.{CheckResult, Labels, Monitor}

  @type display_status ::
          :up | :down | :pending | :maintenance | :unreachable | :warning | :paused

  @type_labels %{
    http: "HTTP(S)",
    keyword: "HTTP(S) keyword",
    tcp: "TCP port",
    ping: "Ping",
    dns: "DNS",
    cert: "TLS certificate",
    push: "Push",
    postgres: "PostgreSQL"
  }

  @doc "A human readable label for a monitor type."
  @spec type_label(atom()) :: String.t()
  def type_label(type), do: Map.get(@type_labels, type, to_string(type))

  @doc "Options for a monitor type select."
  def type_options, do: Enum.map(Monitor.types(), &{type_label(&1), &1})

  @doc """
  The status to display for a monitor: `:paused` when disabled, otherwise
  the status of its latest check result (`:pending` without one).
  """
  @spec display_status(Monitor.t(), CheckResult.t() | nil) :: display_status()
  def display_status(%Monitor{enabled: false}, _latest), do: :paused
  def display_status(_monitor, %CheckResult{status: status}), do: status
  def display_status(_monitor, nil), do: :pending

  @doc """
  The target of a monitor (URL, host:port, host, ...), or nil.
  """
  @spec target(Monitor.t()) :: String.t() | nil
  def target(%Monitor{type: :push}), do: nil
  def target(%Monitor{settings: %{url: url}}) when is_binary(url), do: url

  def target(%Monitor{type: :dns, settings: %{host: host, dns_record_type: type}})
      when is_binary(host),
      do: "#{host} (#{type})"

  def target(%Monitor{type: :postgres, settings: %{host: host, port: port, database: db}})
      when is_binary(host),
      do: "#{host}:#{port}/#{db}"

  def target(%Monitor{settings: %{host: host, port: port}})
      when is_binary(host) and is_integer(port),
      do: "#{host}:#{port}"

  def target(%Monitor{settings: %{host: host}}) when is_binary(host), do: host
  def target(_monitor), do: nil

  @doc """
  The public URL push monitors send their heartbeats to.
  """
  @spec push_url(String.t() | nil) :: String.t() | nil
  def push_url(token) when is_binary(token) and token != "",
    do: url(~p"/api/push/#{token}")

  def push_url(_token), do: nil

  @doc """
  The public URL events are posted to with a monitor's event token (see
  `Sentinelix.Monitoring.Events`).
  """
  @spec event_url(String.t() | nil) :: String.t() | nil
  def event_url(token) when is_binary(token) and token != "",
    do: url(~p"/api/v1/events/#{token}")

  def event_url(_token), do: nil

  @doc "Formats an uptime percentage."
  @spec format_uptime(number() | nil) :: String.t()
  def format_uptime(nil), do: "–"
  def format_uptime(value) when value >= 100, do: "100%"
  def format_uptime(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2) <> "%"

  @doc """
  The badge color class of an uptime percentage: success from 99%,
  warning from 95%, error below, ghost without data.
  """
  @spec uptime_class(number() | nil) :: String.t()
  def uptime_class(nil), do: "badge-ghost"
  def uptime_class(uptime) when uptime >= 99, do: "badge-success"
  def uptime_class(uptime) when uptime >= 95, do: "badge-warning"
  def uptime_class(_uptime), do: "badge-error"

  @doc "Formats a response time in milliseconds."
  @spec format_ms(number() | nil) :: String.t()
  def format_ms(nil), do: "–"
  def format_ms(ms) when ms >= 10_000, do: "#{Float.round(ms / 1000, 1)} s"
  def format_ms(ms), do: "#{round(ms)} ms"

  @doc "Formats a number of seconds as a short duration (\"1h 5m\")."
  @spec format_duration(integer()) :: String.t()
  def format_duration(seconds) when seconds < 60, do: "#{max(seconds, 0)}s"

  def format_duration(seconds) when seconds < 3600 do
    join_units([{div(seconds, 60), "m"}, {rem(seconds, 60), "s"}])
  end

  def format_duration(seconds) when seconds < 86_400 do
    join_units([{div(seconds, 3600), "h"}, {div(rem(seconds, 3600), 60), "m"}])
  end

  def format_duration(seconds) do
    join_units([{div(seconds, 86_400), "d"}, {div(rem(seconds, 86_400), 3600), "h"}])
  end

  defp join_units(parts) do
    parts
    |> Enum.reject(fn {n, _unit} -> n == 0 end)
    |> Enum.map_join(" ", fn {n, unit} -> "#{n}#{unit}" end)
  end

  @doc """
  Formats a timestamp relative to now ("5m ago", "in 30s").
  """
  @spec relative_time(DateTime.t() | nil, DateTime.t()) :: String.t()
  def relative_time(at, now \\ DateTime.utc_now())
  def relative_time(nil, _now), do: "never"

  def relative_time(%DateTime{} = at, now) do
    case DateTime.diff(now, at) do
      diff when diff >= 0 and diff < 5 -> "just now"
      diff when diff >= 0 -> format_duration(diff) <> " ago"
      diff when diff > -5 -> "now"
      diff -> "in " <> format_duration(-diff)
    end
  end

  @doc "Formats a timestamp in UTC (local time is filled in by the LocalTime hook)."
  @spec format_datetime(DateTime.t() | nil) :: String.t()
  def format_datetime(nil), do: "–"
  def format_datetime(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")

  @doc """
  Renders a timestamp that the browser shows in the user's local time zone.
  """
  attr :id, :string, required: true
  attr :at, DateTime, default: nil
  attr :class, :any, default: nil

  def local_time(assigns) do
    ~H"""
    <time
      :if={@at}
      id={@id}
      phx-hook="LocalTime"
      datetime={DateTime.to_iso8601(@at)}
      title={format_datetime(@at)}
      class={@class}
    >
      {format_datetime(@at)}
    </time>
    <span :if={!@at} class={@class}>–</span>
    """
  end

  @doc """
  A status badge (up, down, pending, maintenance, unreachable, paused).
  """
  attr :status, :atom, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm gap-1.5 font-medium", badge_class(@status), @class]} {@rest}>
      <span class={[
        "inline-block size-1.5 rounded-full bg-current",
        @status == :up && "animate-pulse"
      ]} />
      {status_label(@status)}
    </span>
    """
  end

  @doc """
  A badge shown while a monitor is in an active maintenance window (see
  `Sentinelix.Maintenance.active_windows_for/2`). Renders nothing for an
  empty list. The window titles are shown as a tooltip.
  """
  attr :windows, :list, required: true
  attr :class, :any, default: "badge-xs"
  attr :rest, :global

  def maintenance_badge(assigns) do
    ~H"""
    <span
      :if={@windows != []}
      class={["badge badge-info badge-soft gap-1", @class]}
      title={"In maintenance: " <> Enum.map_join(@windows, ", ", & &1.title)}
      {@rest}
    >
      <.icon name="hero-wrench-screwdriver-micro" class="size-3" /> Maintenance
    </span>
    """
  end

  @doc """
  A monitor's labels as `key=value` badges (just `key` for a label without
  a value), sorted by key. Renders nothing without labels. With `patch`, a
  function of the `{key, value}` label returning a path, each badge links
  there (e.g. to filter by the label).

  `automatic` labels (see `Sentinelix.Monitoring.AutoLabels`) follow the
  user's labels as muted, dashed badges, marked with `data-automatic`.
  """
  attr :labels, :map, required: true
  attr :automatic, :map, default: %{}
  attr :class, :any, default: "badge-xs"
  attr :patch, :any, default: nil, doc: "fn {key, value} -> path end"

  def label_badges(assigns) do
    assigns =
      assign(
        assigns,
        :badges,
        Enum.map(Labels.to_list(assigns.labels), &{&1, false}) ++
          Enum.map(Labels.to_list(assigns.automatic), &{&1, true})
      )

    ~H"""
    <%= for {{key, value} = label, automatic} <- @badges do %>
      <.link
        :if={@patch}
        patch={@patch.(label)}
        class={[label_badge_class(automatic), "hover:badge-neutral", @class]}
        title={"Filter by #{Labels.format(label)}"}
        data-label={Labels.format(label)}
        data-automatic={automatic}
      >
        <.label_text key={key} value={value} />
      </.link>
      <span
        :if={!@patch}
        class={[label_badge_class(automatic), @class]}
        title={automatic && "Automatic label"}
        data-label={Labels.format(label)}
        data-automatic={automatic}
      >
        <.label_text key={key} value={value} />
      </span>
    <% end %>
    """
  end

  defp label_badge_class(false), do: "badge badge-ghost gap-0 font-mono"

  defp label_badge_class(true),
    do: "badge badge-outline border-dashed gap-0 font-mono text-base-content/60"

  attr :key, :string, required: true
  attr :value, :string, required: true

  defp label_text(assigns) do
    ~H"""
    <span class={@value != "" && "opacity-70"}>{@key}</span><span :if={@value != ""}>={@value}</span>
    """
  end

  @doc "A human readable status label."
  def status_label(:up), do: "Up"
  def status_label(:down), do: "Down"
  def status_label(:pending), do: "Pending"
  def status_label(:maintenance), do: "Maintenance"
  def status_label(:unreachable), do: "Unreachable"
  def status_label(:warning), do: "Warning"
  def status_label(:paused), do: "Paused"

  defp badge_class(:up), do: "badge-success"
  defp badge_class(:down), do: "badge-error"
  defp badge_class(:pending), do: "badge-warning"
  defp badge_class(:maintenance), do: "badge-info"
  defp badge_class(:unreachable), do: "badge-error badge-soft"
  defp badge_class(:warning), do: "border-amber-500 bg-amber-500 text-white"
  defp badge_class(:paused), do: "badge-ghost"

  @doc """
  The color class used for a status (text color).
  """
  def status_text_class(:up), do: "text-success"
  def status_text_class(:down), do: "text-error"
  def status_text_class(:pending), do: "text-warning"
  def status_text_class(:maintenance), do: "text-info"
  def status_text_class(:unreachable), do: "text-error/70"
  def status_text_class(:warning), do: "text-amber-500"
  def status_text_class(_status), do: "text-base-content/50"

  @doc """
  The icon of a status, so a status reads without its color: a check for
  up, a cross for down, a "no" sign for unreachable, a clock for pending,
  a wrench for maintenance, a warning sign for warning and a pause sign
  for paused.
  """
  @spec status_icon_name(atom()) :: String.t()
  def status_icon_name(:up), do: "hero-check-circle-mini"
  def status_icon_name(:down), do: "hero-x-circle-mini"
  def status_icon_name(:unreachable), do: "hero-no-symbol-mini"
  def status_icon_name(:pending), do: "hero-clock-mini"
  def status_icon_name(:maintenance), do: "hero-wrench-screwdriver-mini"
  def status_icon_name(:warning), do: "hero-exclamation-triangle-mini"
  def status_icon_name(:paused), do: "hero-pause-circle-mini"
  def status_icon_name(_status), do: "hero-question-mark-circle-mini"

  @doc """
  The icon of a status (see `status_icon_name/1`). Decorative: put the
  status label next to it, visibly or for screen readers.
  """
  attr :status, :atom, required: true
  attr :class, :any, default: "size-4"

  def status_icon(assigns) do
    ~H"""
    <.icon name={status_icon_name(@status)} class={["shrink-0", @class]} />
    """
  end

  @doc """
  A monitor as a tile colored by its status, linking to the monitor.

  Status shows by color, icon and, for screen readers, its label (the
  link reads as "name, status"); unreachable and paused tiles also have a
  dashed border. The details (status, last response time, 24h uptime,
  warning and maintenance) show as a tooltip on hover and keyboard focus,
  and are the tile's accessible description.

  With `navigate={false}` the tile is a plain box instead: no link and no
  tooltip (wall displays have nothing to click and nothing behind a login
  to link to). The maintenance windows then only switch the icon on;
  their titles aren't shown.

  Sizes:

    * `"sm"` – a small tile with the name, for many monitors on a screen
      (the dashboard's grid).
    * `"lg"` – a large tile that also shows the status, response time and
      uptime, readable from a distance (wall displays).
  """
  attr :id, :string, required: true
  attr :monitor, :map, required: true, doc: "with `id` and `name`"
  attr :status, :atom, required: true
  attr :response_time_ms, :any, default: nil, doc: "the latest response time"
  attr :uptime, :any, default: nil, doc: "the uptime percentage, `nil` without checks"
  attr :warning, :boolean, default: false
  attr :maintenance, :list, default: [], doc: "the active maintenance windows"
  attr :size, :string, values: ~w(sm lg), default: "sm"
  attr :navigate, :any, default: nil, doc: "defaults to the monitor's page, `false` for no link"
  attr :class, :any, default: nil
  attr :rest, :global

  def monitor_tile(%{navigate: false} = assigns) do
    ~H"""
    <div
      id={@id}
      data-status={@status}
      class={[
        "relative flex rounded-field border",
        tile_size_class(@size),
        status_tile_class(@status),
        @class
      ]}
      {@rest}
    >
      <.tile_content
        monitor={@monitor}
        status={@status}
        size={@size}
        response_time_ms={@response_time_ms}
        uptime={@uptime}
        warning={@warning}
        maintenance={@maintenance}
      />
    </div>
    """
  end

  def monitor_tile(assigns) do
    assigns =
      assign(assigns,
        details_id: assigns.id <> "-details",
        navigate: assigns.navigate || ~p"/monitors/#{assigns.monitor.id}"
      )

    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      aria-describedby={@details_id}
      data-status={@status}
      class={[
        "group/tile relative flex rounded-field border transition hover:brightness-95",
        "focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content focus-visible:ring-offset-1",
        tile_size_class(@size),
        status_tile_class(@status),
        @class
      ]}
      {@rest}
    >
      <.tile_content
        monitor={@monitor}
        status={@status}
        size={@size}
        response_time_ms={@response_time_ms}
        uptime={@uptime}
        warning={@warning}
        maintenance={@maintenance}
      />
      <span
        id={@details_id}
        role="tooltip"
        class={[
          "pointer-events-none absolute bottom-full left-1/2 z-20 mb-1 hidden w-56 -translate-x-1/2",
          "rounded-box border border-base-300 bg-base-100 p-2 text-left text-xs font-normal text-base-content shadow-lg",
          "group-hover/tile:block group-focus-visible/tile:block"
        ]}
      >
        <span class="block break-words font-medium">{@monitor.name}</span>
        <span class={["flex items-center gap-1", status_text_class(@status)]}>
          <.status_icon status={@status} class="size-3" />{status_label(@status)}
        </span>
        <span class="block tabular-nums">
          Response time: {format_ms(@response_time_ms)}
        </span>
        <span class="block tabular-nums">Uptime (24h): {format_uptime(@uptime)}</span>
        <span :if={@warning} class="block text-warning">Warning</span>
        <span :if={@maintenance != []} class="block">
          In maintenance: {Enum.map_join(@maintenance, ", ", & &1.title)}
        </span>
      </span>
    </.link>
    """
  end

  attr :monitor, :map, required: true
  attr :status, :atom, required: true
  attr :size, :string, required: true
  attr :response_time_ms, :any, required: true
  attr :uptime, :any, required: true
  attr :warning, :boolean, required: true
  attr :maintenance, :list, required: true

  defp tile_content(assigns) do
    ~H"""
    <span class="flex min-w-0 items-center gap-1.5">
      <span class={@status != :down && status_text_class(@status)}>
        <.status_icon status={@status} class={tile_icon_class(@size)} />
      </span>
      <span class="min-w-0 truncate font-medium">{@monitor.name}</span>
      <span :if={@size == "sm"} class="sr-only">, {status_label(@status)}</span>
      <.icon
        :if={@warning}
        name="hero-exclamation-triangle-micro"
        class="size-3 shrink-0 text-warning"
      />
      <.icon
        :if={@maintenance != []}
        name="hero-wrench-screwdriver-micro"
        class="size-3 shrink-0"
      />
    </span>
    <span :if={@size == "lg"} class="flex items-baseline gap-3 text-sm tabular-nums">
      <span class="font-semibold">{status_label(@status)}</span>
      <span>{format_ms(@response_time_ms)}</span>
      <span>{format_uptime(@uptime)}</span>
    </span>
    """
  end

  defp tile_size_class("sm"), do: "h-9 items-center px-2 text-xs"
  defp tile_size_class("lg"), do: "h-28 flex-col justify-between p-3 text-lg"

  defp tile_icon_class("sm"), do: "size-4"
  defp tile_icon_class("lg"), do: "size-6"

  @doc """
  The border and background classes of something colored by a status (a
  tile, a matrix cell). Down is solid; unreachable and paused are dashed,
  so they differ from down and up by more than their color.
  """
  @spec status_tile_class(atom()) :: String.t()
  def status_tile_class(:up), do: "border-success/50 bg-success/15"
  def status_tile_class(:down), do: "border-error bg-error text-error-content"
  def status_tile_class(:unreachable), do: "border-dashed border-error/70 bg-error/25"
  def status_tile_class(:pending), do: "border-warning bg-warning/25"
  def status_tile_class(:maintenance), do: "border-info/60 bg-info/15"
  def status_tile_class(:warning), do: "border-amber-500 bg-amber-500/25"

  def status_tile_class(:paused),
    do: "border-dashed border-base-content/30 bg-base-200 text-base-content/60"

  def status_tile_class(_status), do: "border-base-content/30 bg-base-200"

  @doc """
  A heartbeat bar: one pill per check result (oldest first), right
  aligned, padded with empty pills up to `slots`. Older pills are cut off
  on narrow screens.
  """
  attr :id, :string, required: true
  attr :results, :list, required: true, doc: "check results, oldest first"
  attr :slots, :integer, default: 50
  attr :class, :any, default: nil
  attr :size, :string, values: ~w(sm md), default: "sm"

  def heartbeat_bar(assigns) do
    results = Enum.take(assigns.results, -assigns.slots)

    assigns =
      assigns
      |> assign(:pills, Enum.reverse(results))
      |> assign(:empty, assigns.slots - length(results))

    ~H"""
    <div
      id={@id}
      class={["flex flex-row-reverse items-center justify-start gap-[3px] overflow-hidden", @class]}
      aria-label="Recent checks"
    >
      <span
        :for={result <- @pills}
        class={[
          "shrink-0 rounded-full transition-transform hover:scale-125",
          pill_size(@size),
          pill_class(result.status)
        ]}
        title={pill_title(result)}
        data-status={result.status}
      />
      <span
        :for={_ <- 1..@empty//1}
        class={["shrink-0 rounded-full bg-base-content/10", pill_size(@size)]}
      />
    </div>
    """
  end

  defp pill_size("sm"), do: "h-5 w-1.5"
  defp pill_size("md"), do: "h-8 w-2"

  defp pill_class(:up), do: "bg-success"
  defp pill_class(:down), do: "bg-error"
  defp pill_class(:pending), do: "bg-warning"
  defp pill_class(:maintenance), do: "bg-info"
  defp pill_class(:unreachable), do: "bg-error/40"
  defp pill_class(:warning), do: "bg-amber-500"

  defp pill_title(result) do
    [
      format_datetime(result.checked_at),
      status_label(result.status),
      result.response_time_ms && format_ms(result.response_time_ms),
      result.message
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc """
  A daily uptime bar: one bar per day (oldest first, as returned by
  `Sentinelix.Stats.daily_uptime/3`), colored by the day's uptime. Older
  days are cut off on narrow screens.
  """
  attr :id, :string, required: true
  attr :days, :list, required: true, doc: "`%{date, uptime, maintenance}` maps, oldest first"
  attr :class, :any, default: nil

  def daily_uptime_bar(assigns) do
    assigns = assign(assigns, :bars, Enum.reverse(assigns.days))

    ~H"""
    <div
      id={@id}
      class={[
        "flex h-8 flex-row-reverse items-stretch justify-start gap-[2px] overflow-hidden",
        @class
      ]}
      aria-label="Daily uptime"
    >
      <span
        :for={day <- @bars}
        class={["w-1.5 shrink-0 rounded-sm sm:w-auto sm:flex-1", day_class(day)]}
        title={day_title(day)}
        data-date={Date.to_iso8601(day.date)}
      />
    </div>
    """
  end

  defp day_class(%{uptime: nil, maintenance: n}) when n > 0, do: "bg-info"
  defp day_class(%{uptime: nil}), do: "bg-base-content/10"
  defp day_class(%{uptime: uptime}) when uptime >= 99, do: "bg-success"
  defp day_class(%{uptime: uptime}) when uptime >= 95, do: "bg-warning"
  defp day_class(_day), do: "bg-error"

  defp day_title(%{date: date, uptime: nil, maintenance: n}) when n > 0,
    do: "#{date} · Maintenance"

  defp day_title(%{date: date, uptime: nil}), do: "#{date} · No data"
  defp day_title(%{date: date, uptime: uptime}), do: "#{date} · #{format_uptime(uptime)} uptime"

  @doc """
  A stat tile with a title, a value and an optional description.
  """
  attr :title, :string, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :desc

  def stat_card(assigns) do
    ~H"""
    <div id={@id} class={["rounded-box border border-base-300 bg-base-100 p-4", @class]}>
      <div class="text-xs font-medium uppercase tracking-wide text-base-content/60">{@title}</div>
      <div class="mt-1 text-2xl font-semibold tabular-nums">{render_slot(@inner_block)}</div>
      <div :if={@desc != []} class="mt-1 text-xs text-base-content/60">{render_slot(@desc)}</div>
    </div>
    """
  end
end
