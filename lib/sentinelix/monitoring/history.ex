defmodule Sentinelix.Monitoring.History do
  @moduledoc """
  Read-only queries over the check result history used by the web UI:
  heartbeat bars, uptime percentages and response time series.

  The uptime functions compute directly from the raw `check_results` rows.
  They are deliberately small so they can be backed by the statistics
  module (rollups, #9) without touching the UI.
  """

  import Ecto.Query, warn: false

  alias Sentinelix.Monitoring.{CheckResult, Monitor}
  alias Sentinelix.Repo

  @type point :: %{at: DateTime.t(), response_time_ms: integer() | nil, down: boolean()}

  @doc """
  Returns the `limit` most recent check results of every monitor (or of the
  given monitor ids) as a map of monitor id => results, **oldest first**.

  Monitors without results are not included in the map.
  """
  @spec recent_results_by_monitor(pos_integer(), [pos_integer()] | nil) :: %{
          pos_integer() => [CheckResult.t()]
        }
  def recent_results_by_monitor(limit, monitor_ids \\ nil) do
    latest =
      from r in CheckResult,
        where: r.monitor_id == parent_as(:monitor).id,
        order_by: [desc: r.checked_at, desc: r.id],
        limit: ^limit,
        select: r

    Monitor
    |> from(as: :monitor)
    |> then(fn q -> if monitor_ids, do: where(q, [m], m.id in ^monitor_ids), else: q end)
    |> join(:inner_lateral, [m], r in subquery(latest), on: true)
    |> select([_m, r], r)
    |> Repo.all()
    |> Enum.group_by(& &1.monitor_id)
    |> Map.new(fn {id, results} ->
      {id, Enum.sort_by(results, &{DateTime.to_unix(&1.checked_at, :microsecond), &1.id})}
    end)
  end

  @doc """
  Uptime percentage (0.0–100.0) per monitor since `since`, as a map of
  monitor id => percentage. Only monitors with at least one `:up` or
  `:down` result in the window are included.

  `:up` results count as up and `:down` results as down; `:pending`
  (retrying) and `:maintenance` results are left out of the calculation.
  """
  @spec uptime_by_monitor(DateTime.t(), [pos_integer()] | nil) :: %{pos_integer() => float()}
  def uptime_by_monitor(%DateTime{} = since, monitor_ids \\ nil) do
    CheckResult
    |> where([r], r.checked_at >= ^since and r.status in [:up, :down])
    |> then(fn q -> if monitor_ids, do: where(q, [r], r.monitor_id in ^monitor_ids), else: q end)
    |> group_by([r], r.monitor_id)
    |> select([r], {r.monitor_id, count(r.id), filter(count(r.id), r.status == :up)})
    |> Repo.all()
    |> Map.new(fn {id, total, up} -> {id, up * 100 / total} end)
  end

  @doc """
  Uptime percentage of a single monitor since `since`, or `nil` without
  data. See `uptime_by_monitor/2`.
  """
  @spec uptime(Monitor.t() | pos_integer(), DateTime.t()) :: float() | nil
  def uptime(monitor, %DateTime{} = since) do
    id = monitor_id(monitor)
    since |> uptime_by_monitor([id]) |> Map.get(id)
  end

  @doc """
  Average response time (ms) of a monitor's `:up` results since `since`,
  or `nil` without data.
  """
  @spec average_response_time(Monitor.t() | pos_integer(), DateTime.t()) :: float() | nil
  def average_response_time(monitor, %DateTime{} = since) do
    id = monitor_id(monitor)

    CheckResult
    |> where([r], r.monitor_id == ^id and r.checked_at >= ^since and r.status == :up)
    |> select([r], avg(r.response_time_ms))
    |> Repo.one()
    |> case do
      nil -> nil
      %Decimal{} = avg -> Decimal.to_float(avg)
      avg -> avg / 1
    end
  end

  @doc """
  The response time series of a monitor since `since`, oldest first.

  Without `:bucket_seconds` every result is a point. With it, results are
  grouped into buckets of that many seconds: the point's response time is
  the bucket's average and `down` is true if any check in the bucket was
  down.
  """
  @spec response_times(Monitor.t() | pos_integer(), DateTime.t(), keyword()) :: [point()]
  def response_times(monitor, %DateTime{} = since, opts \\ []) do
    id = monitor_id(monitor)

    base =
      CheckResult
      |> where([r], r.monitor_id == ^id and r.checked_at >= ^since)
      |> where([r], r.status != :maintenance)

    case Keyword.get(opts, :bucket_seconds) do
      nil ->
        base
        |> order_by([r], asc: r.checked_at, asc: r.id)
        |> select([r], %{
          at: r.checked_at,
          response_time_ms: r.response_time_ms,
          down: r.status == :down
        })
        |> Repo.all()

      bucket when is_integer(bucket) and bucket > 0 ->
        bucketed =
          select(base, [r], %{
            bucket:
              fragment(
                "to_timestamp(floor(extract(epoch from ?) / ?) * ?) AT TIME ZONE 'UTC'",
                r.checked_at,
                ^bucket,
                ^bucket
              ),
            response_time_ms: r.response_time_ms,
            status: r.status
          })

        from(b in subquery(bucketed),
          group_by: b.bucket,
          order_by: b.bucket,
          select: %{
            at: type(b.bucket, :utc_datetime_usec),
            response_time_ms: type(fragment("round(avg(?))", b.response_time_ms), :integer),
            down: fragment("bool_or(? = 'down')", b.status)
          }
        )
        |> Repo.all()
    end
  end

  defp monitor_id(%Monitor{id: id}), do: id
  defp monitor_id(id) when is_integer(id), do: id
end
