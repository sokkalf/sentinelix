defmodule Sentinelix.Stats do
  @moduledoc """
  Uptime and response time statistics.

  ## Windows

  Functions take a window: `{n, :hour}` or `{n, :day}` (the last `n`
  hours/days up to now, e.g. `{24, :hour}`, `{7, :day}`, `{90, :day}`) or an
  explicit `{from, to}` pair of `DateTime`s (`from` inclusive, `to`
  exclusive). All functions accept a `:now` option (default
  `DateTime.utc_now/0`).

  ## Data sources

  Raw `check_results` are kept for a limited time and rolled up into hourly
  rows (see `Sentinelix.Stats.Rollup`). A window is answered from the
  rollups for the complete hours before the rollup watermark and from the
  raw results for the rest (the partial hour at the start of the window and
  everything since the watermark), so queries over 30 or 90 days stay
  cheap and the numbers are exact as long as the raw results of the partial
  first hour still exist.

  ## Semantics

    * Uptime is `up / (up + down + unreachable)` as a percentage
      (`0.0..100.0`). `:maintenance` results and `:pending` results (a
      failed check that is being retried and not yet confirmed down) are
      excluded from the denominator. `:unreachable` results (failed while
      the monitor's parent was down) count as downtime: the service wasn't
      available, the parent only explains why and keeps the alert quiet.
      `nil` when there are no up, down or unreachable results.
    * `:warning` results (up, with a warning raised by an event) count as
      `:up`, here and in the rollups.
    * Response time statistics cover `:up` results only (the response time
      of a failed check is mostly its timeout). `p95_ms` is computed from
      the raw results only, so for windows longer than the raw retention it
      covers the retained part.
    * Days (`daily_uptime/3`) are UTC days.
  """

  import Ecto.Query

  alias Sentinelix.Monitoring.{CheckResult, Monitor}
  alias Sentinelix.Repo
  alias Sentinelix.Stats.{HourlyStat, Rollup}

  # Statuses counted as up (see Semantics).
  @up_statuses [:up, :warning]

  @doc "The check result statuses that count as up: `:up` and `:warning`."
  @spec up_statuses() :: [atom()]
  def up_statuses, do: @up_statuses

  @type window ::
          {pos_integer(), :hour | :day} | {DateTime.t(), DateTime.t()}
  @type monitor_ref :: Monitor.t() | pos_integer()

  @type summary :: %{
          uptime: float() | nil,
          up: non_neg_integer(),
          down: non_neg_integer(),
          pending: non_neg_integer(),
          maintenance: non_neg_integer(),
          unreachable: non_neg_integer(),
          total: non_neg_integer(),
          avg_ms: float() | nil,
          min_ms: non_neg_integer() | nil,
          max_ms: non_neg_integer() | nil
        }

  @type day :: %{
          date: Date.t(),
          uptime: float() | nil,
          up: non_neg_integer(),
          down: non_neg_integer(),
          pending: non_neg_integer(),
          maintenance: non_neg_integer(),
          unreachable: non_neg_integer()
        }

  @empty %{
    up: 0,
    down: 0,
    pending: 0,
    maintenance: 0,
    unreachable: 0,
    response_count: 0,
    response_sum: nil,
    min_ms: nil,
    max_ms: nil
  }

  ## Public API

  @doc """
  Uptime percentage of a monitor over `window`, or `nil` without data.

      Stats.uptime(monitor, {24, :hour})
      #=> 99.93
  """
  @spec uptime(monitor_ref(), window(), keyword()) :: float() | nil
  def uptime(monitor, window, opts \\ []) do
    id = monitor_id(monitor)
    uptimes([id], window, opts)[id]
  end

  @doc """
  Uptime percentages of many monitors over `window` in one go, as a map of
  monitor id => percentage (or `nil`). For dashboards.
  """
  @spec uptimes([monitor_ref()], window(), keyword()) :: %{pos_integer() => float() | nil}
  def uptimes(monitors, window, opts \\ []) do
    monitors
    |> summaries(window, opts)
    |> Map.new(fn {id, summary} -> {id, summary.uptime} end)
  end

  @doc """
  Uptime and response time summary of a monitor over `window`; see
  `t:summary/0`, plus `p95_ms` (95th percentile response time).
  """
  @spec summary(monitor_ref(), window(), keyword()) ::
          %{required(:p95_ms) => float() | nil, optional(atom()) => term()}
  def summary(monitor, window, opts \\ []) do
    id = monitor_id(monitor)
    {from, to} = window_range(window, opts)

    [id]
    |> summaries({from, to}, opts)
    |> Map.fetch!(id)
    |> Map.put(:p95_ms, p95(id, from, to))
  end

  @doc """
  Summaries (`t:summary/0`, without `p95_ms`) of many monitors over
  `window`, as a map of monitor id => summary. Monitors without data get an
  empty summary.
  """
  @spec summaries([monitor_ref()], window(), keyword()) :: %{pos_integer() => summary()}
  def summaries(monitors, window, opts \\ []) do
    ids = Enum.map(monitors, &monitor_id/1)
    {from, to} = window_range(window, opts)
    rows = aggregate(ids, from, to, :none)

    Map.new(ids, fn id -> {id, to_summary(Map.get(rows, {id, nil}, @empty))} end)
  end

  @doc """
  Per-day uptime over the last `days` UTC days including today (oldest
  first), e.g. for 90-day uptime bars. Days without data have
  `uptime: nil`.

  Given a monitor (or id) returns a list of `t:day/0`; given a list of
  monitors returns a map of monitor id => list, computed in one go.
  """
  @spec daily_uptime(monitor_ref() | [monitor_ref()], pos_integer(), keyword()) ::
          [day()] | %{pos_integer() => [day()]}
  def daily_uptime(monitors, days, opts \\ [])

  def daily_uptime(monitors, days, opts) when is_list(monitors) do
    ids = Enum.map(monitors, &monitor_id/1)
    now = now(opts)
    today = DateTime.to_date(now)
    dates = Enum.map((days - 1)..0//-1, &Date.add(today, -&1))
    from = DateTime.new!(hd(dates), ~T[00:00:00], "Etc/UTC")

    rows = aggregate(ids, from, now, :day)

    Map.new(ids, fn id ->
      {id,
       Enum.map(dates, fn date ->
         counts = Map.get(rows, {id, date}, @empty)

         %{
           date: date,
           uptime: uptime_percent(counts),
           up: counts.up,
           down: counts.down,
           pending: counts.pending,
           maintenance: counts.maintenance,
           unreachable: counts.unreachable
         }
       end)}
    end)
  end

  def daily_uptime(monitor, days, opts) do
    id = monitor_id(monitor)
    daily_uptime([id], days, opts)[id]
  end

  @doc """
  Hourly statistics of a monitor over `window` (oldest first; hours without
  results are omitted), e.g. for response time charts over long ranges.
  Each entry is a `t:summary/0` plus `:hour` (start of the UTC hour).
  """
  @spec hourly(monitor_ref(), window(), keyword()) :: [map()]
  def hourly(monitor, window, opts \\ []) do
    id = monitor_id(monitor)
    {from, to} = window_range(window, opts)

    id
    |> List.wrap()
    |> aggregate(from, to, :hour)
    |> Enum.map(fn {{_id, hour}, counts} -> Map.put(to_summary(counts), :hour, hour) end)
    |> Enum.sort_by(& &1.hour, DateTime)
  end

  @doc """
  Resolves a window to a `{from, to}` pair of `DateTime`s.
  """
  @spec window_range(window(), keyword()) :: {DateTime.t(), DateTime.t()}
  def window_range(window, opts \\ [])

  def window_range({%DateTime{} = from, %DateTime{} = to}, _opts), do: {from, to}

  def window_range({n, unit}, opts) when is_integer(n) and n > 0 and unit in [:hour, :day] do
    now = now(opts)
    {DateTime.add(now, -n, unit), now}
  end

  @doc false
  @spec floor_hour(DateTime.t()) :: DateTime.t()
  def floor_hour(%DateTime{} = dt), do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}

  ## Aggregation

  # Returns %{{monitor_id, bucket} => counts}, where bucket is nil, the hour
  # (DateTime) or the day (Date).
  defp aggregate([], _from, _to, _bucket), do: %{}

  defp aggregate(ids, from, to, bucket) do
    {rollup_range, raw_ranges} = plan(from, to)

    raw = if raw_ranges == [], do: [], else: Repo.all(raw_query(ids, raw_ranges, bucket))
    rollups = if rollup_range, do: Repo.all(rollup_query(ids, rollup_range, bucket)), else: []

    (raw ++ rollups)
    |> Enum.map(&normalize_bucket(&1, bucket))
    |> Enum.group_by(&{&1.monitor_id, &1.bucket})
    |> Map.new(fn {key, rows} -> {key, Enum.reduce(rows, @empty, &merge/2)} end)
  end

  # Splits [from, to) into the complete hours covered by rollups and the
  # ranges that have to be read from the raw results.
  defp plan(from, to) do
    rollup_start = ceil_hour(from)
    watermark = Rollup.watermark()
    rollup_end = watermark && Enum.min([watermark, floor_hour(to)], DateTime)

    if rollup_end && DateTime.after?(rollup_end, rollup_start) do
      raw =
        Enum.reject([{from, rollup_start}, {rollup_end, to}], fn {a, b} ->
          not DateTime.before?(a, b)
        end)

      {{rollup_start, rollup_end}, raw}
    else
      {nil, if(DateTime.before?(from, to), do: [{from, to}], else: [])}
    end
  end

  defp raw_query(ids, ranges, bucket) do
    in_ranges =
      Enum.reduce(ranges, dynamic(false), fn {a, b}, acc ->
        dynamic([r], ^acc or (r.checked_at >= ^a and r.checked_at < ^b))
      end)

    query =
      from r in CheckResult,
        where: r.monitor_id in ^ids,
        where: ^in_ranges,
        group_by: r.monitor_id,
        select: %{
          monitor_id: r.monitor_id,
          up: filter(count(), r.status in ^@up_statuses),
          down: filter(count(), r.status == ^:down),
          pending: filter(count(), r.status == ^:pending),
          maintenance: filter(count(), r.status == ^:maintenance),
          unreachable: filter(count(), r.status == ^:unreachable),
          response_count: filter(count(r.response_time_ms), r.status in ^@up_statuses),
          response_sum: filter(sum(r.response_time_ms), r.status in ^@up_statuses),
          min_ms: filter(min(r.response_time_ms), r.status in ^@up_statuses),
          max_ms: filter(max(r.response_time_ms), r.status in ^@up_statuses)
        }

    case bucket do
      :none ->
        query

      :hour ->
        query
        |> group_by([r], fragment("date_trunc('hour', ?)", r.checked_at))
        |> select_merge([r], %{
          bucket: type(fragment("date_trunc('hour', ?)", r.checked_at), :utc_datetime)
        })

      :day ->
        query
        |> group_by([r], fragment("date_trunc('day', ?)", r.checked_at))
        |> select_merge([r], %{
          bucket: type(fragment("date_trunc('day', ?)", r.checked_at), :utc_datetime)
        })
    end
  end

  defp rollup_query(ids, {from, to}, bucket) do
    query =
      from h in HourlyStat,
        where: h.monitor_id in ^ids and h.hour >= ^from and h.hour < ^to,
        group_by: h.monitor_id,
        select: %{
          monitor_id: h.monitor_id,
          up: sum(h.up_count),
          down: sum(h.down_count),
          pending: sum(h.pending_count),
          maintenance: sum(h.maintenance_count),
          unreachable: sum(h.unreachable_count),
          response_count: sum(h.response_count),
          response_sum: fragment("sum(? * ?)", h.avg_ms, h.response_count),
          min_ms: min(h.min_ms),
          max_ms: max(h.max_ms)
        }

    case bucket do
      :none ->
        query

      :hour ->
        query
        |> group_by([h], h.hour)
        |> select_merge([h], %{bucket: h.hour})

      :day ->
        query
        |> group_by([h], fragment("date_trunc('day', ?)", h.hour))
        |> select_merge([h], %{
          bucket: type(fragment("date_trunc('day', ?)", h.hour), :utc_datetime)
        })
    end
  end

  defp p95(id, from, to) do
    Repo.one(
      from r in CheckResult,
        where:
          r.monitor_id == ^id and r.status in ^@up_statuses and
            not is_nil(r.response_time_ms) and
            r.checked_at >= ^from and r.checked_at < ^to,
        select:
          type(
            fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", r.response_time_ms),
            :float
          )
    )
  end

  defp normalize_bucket(row, :none), do: Map.put(row, :bucket, nil)
  defp normalize_bucket(row, :hour), do: row
  defp normalize_bucket(row, :day), do: Map.update!(row, :bucket, &DateTime.to_date/1)

  defp merge(row, acc) do
    %{
      up: acc.up + (row.up || 0),
      down: acc.down + (row.down || 0),
      pending: acc.pending + (row.pending || 0),
      maintenance: acc.maintenance + (row.maintenance || 0),
      unreachable: acc.unreachable + (row.unreachable || 0),
      response_count: acc.response_count + (row.response_count || 0),
      response_sum: add(acc.response_sum, row.response_sum),
      min_ms: pick(acc.min_ms, row.min_ms, &min/2),
      max_ms: pick(acc.max_ms, row.max_ms, &max/2)
    }
  end

  defp add(nil, b), do: b
  defp add(a, nil), do: a
  defp add(a, b), do: a + b

  defp pick(nil, b, _fun), do: b
  defp pick(a, nil, _fun), do: a
  defp pick(a, b, fun), do: fun.(a, b)

  defp to_summary(counts) do
    %{
      uptime: uptime_percent(counts),
      up: counts.up,
      down: counts.down,
      pending: counts.pending,
      maintenance: counts.maintenance,
      unreachable: counts.unreachable,
      total: counts.up + counts.down + counts.pending + counts.maintenance + counts.unreachable,
      avg_ms: avg(counts),
      min_ms: counts.min_ms,
      max_ms: counts.max_ms
    }
  end

  @doc """
  The uptime percentage of result counts (`:up`, `:down` and `:unreachable`
  counts; other keys are ignored), see Semantics. `nil` without any.
  """
  @spec uptime_percent(map()) :: float() | nil
  def uptime_percent(counts) do
    up = Map.get(counts, :up, 0)
    unavailable = Map.get(counts, :down, 0) + Map.get(counts, :unreachable, 0)
    if up + unavailable == 0, do: nil, else: up * 100 / (up + unavailable)
  end

  defp avg(%{response_count: 0}), do: nil
  defp avg(%{response_sum: nil}), do: nil
  defp avg(%{response_sum: sum, response_count: count}), do: sum / count

  ## Helpers

  defp ceil_hour(%DateTime{} = dt) do
    floored = floor_hour(dt)
    if DateTime.compare(floored, dt) == :eq, do: floored, else: DateTime.add(floored, 1, :hour)
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp monitor_id(%Monitor{id: id}), do: id
  defp monitor_id(id) when is_integer(id), do: id
end
