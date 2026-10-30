defmodule Sentinelix.Monitoring.History do
  @moduledoc """
  Read-only queries over the raw check result history used by the web UI:
  heartbeat bars and short-range response time series. Uptime and
  aggregated response time statistics live in `Sentinelix.Stats`.
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
  The response time series of a monitor since `since`, one point per check
  result (except `:maintenance`), oldest first. For longer ranges use the
  hourly buckets of `Sentinelix.Stats.hourly/3`.
  """
  @spec response_times(Monitor.t() | pos_integer(), DateTime.t()) :: [point()]
  def response_times(monitor, %DateTime{} = since) do
    id = monitor_id(monitor)

    CheckResult
    |> where([r], r.monitor_id == ^id and r.checked_at >= ^since)
    |> where([r], r.status != :maintenance)
    |> order_by([r], asc: r.checked_at, asc: r.id)
    |> select([r], %{
      at: r.checked_at,
      response_time_ms: r.response_time_ms,
      down: r.status == :down
    })
    |> Repo.all()
  end

  defp monitor_id(%Monitor{id: id}), do: id
  defp monitor_id(id) when is_integer(id), do: id
end
