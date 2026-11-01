defmodule Sentinelix.Stats.Rollup do
  @moduledoc """
  Builds the hourly rollups (`Sentinelix.Stats.HourlyStat`) from the raw
  check results and prunes old data. Run periodically by
  `Sentinelix.Stats.Scheduler`; both operations are idempotent, so running
  them more often (or on several nodes) is harmless.

  ## Rollups

  `run/1` aggregates every complete hour since the last run (re-aggregating
  the hour before the previous watermark too, to pick up results that were
  recorded late) and then advances the watermark (see
  `Sentinelix.Stats.RollupState`) to the start of the current hour. Hours
  are recomputed from the raw results and upserted, never incremented.

  ## Retention

  `prune/1` deletes

    * raw check results older than `:retention_days` (default 90) – but
      never results that are not yet covered by a rollup,
    * rollups older than `:rollup_retention_days` (default 365),
    * monitor events (`Sentinelix.Monitoring.Events`) older than
      `:retention_days`, like the raw results.

  Both are read from `config :sentinelix, Sentinelix.Stats` (see
  `config/runtime.exs` for the `RETENTION_DAYS` and
  `ROLLUP_RETENTION_DAYS` environment variables). `nil` or `0` keeps the
  data forever.
  """

  import Ecto.Query

  alias Sentinelix.Monitoring.{CheckResult, Events, Monitor}
  alias Sentinelix.Repo
  alias Sentinelix.Stats
  alias Sentinelix.Stats.{HourlyStat, RollupState}

  @state_id 1
  @overlap_seconds 3_600
  @prune_batch_size 10_000
  @replace_fields [
    :up_count,
    :down_count,
    :pending_count,
    :maintenance_count,
    :unreachable_count,
    :response_count,
    :avg_ms,
    :min_ms,
    :max_ms
  ]

  @doc """
  The rollup watermark: results before it are covered by the hourly
  rollups. `nil` if the rollup never ran.
  """
  @spec watermark() :: DateTime.t() | nil
  def watermark do
    Repo.one(from s in RollupState, where: s.id == @state_id, select: s.rolled_up_until)
  end

  @doc """
  Rolls up all complete hours since the last run.

  Options: `:now` (default `DateTime.utc_now/0`).

  Returns `{:ok, number_of_hourly_rows_written}`.
  """
  @spec run(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    until = Stats.floor_hour(now)

    Repo.transaction(fn ->
      # Serialises concurrent runs (e.g. on several nodes).
      previous =
        Repo.one(
          from s in RollupState,
            where: s.id == @state_id,
            select: s.rolled_up_until,
            lock: "FOR UPDATE"
        )

      since = previous && DateTime.add(previous, -@overlap_seconds, :second)

      if since && not DateTime.before?(since, until),
        do: 0,
        else: rollup(since, until, previous)
    end)
  end

  defp rollup(since, until, previous) do
    {count, _} =
      Repo.insert_all(HourlyStat, rollup_query(since, until),
        on_conflict: {:replace, @replace_fields},
        conflict_target: [:monitor_id, :hour]
      )

    if is_nil(previous) or DateTime.after?(until, previous) do
      Repo.insert!(%RollupState{id: @state_id, rolled_up_until: until},
        on_conflict: [set: [rolled_up_until: until]],
        conflict_target: :id
      )
    end

    count
  end

  defp rollup_query(since, until) do
    # `:warning` results count as up (see Semantics in Sentinelix.Stats).
    up = Stats.up_statuses()

    query =
      from r in CheckResult,
        where: r.checked_at < ^until,
        group_by: [r.monitor_id, fragment("date_trunc('hour', ?)", r.checked_at)],
        select: %{
          monitor_id: r.monitor_id,
          hour: fragment("date_trunc('hour', ?)", r.checked_at),
          up_count: filter(count(), r.status in ^up),
          down_count: filter(count(), r.status == ^:down),
          pending_count: filter(count(), r.status == ^:pending),
          maintenance_count: filter(count(), r.status == ^:maintenance),
          unreachable_count: filter(count(), r.status == ^:unreachable),
          response_count: filter(count(r.response_time_ms), r.status in ^up),
          avg_ms: filter(avg(r.response_time_ms), r.status in ^up),
          min_ms: filter(min(r.response_time_ms), r.status in ^up),
          max_ms: filter(max(r.response_time_ms), r.status in ^up)
        }

    if since, do: where(query, [r], r.checked_at >= ^since), else: query
  end

  @doc """
  Deletes raw results and rollups past their retention.

  Options (default to the application config): `:retention_days`,
  `:rollup_retention_days`, `:now` and `:batch_size` (raw results deleted
  per statement, default #{@prune_batch_size}).

  Returns the number of deleted rows.
  """
  @spec prune(keyword()) :: %{
          results: non_neg_integer(),
          rollups: non_neg_integer(),
          events: non_neg_integer()
        }
  def prune(opts \\ []) do
    config = Application.get_env(:sentinelix, Stats, [])
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    retention_days = Keyword.get(opts, :retention_days, config[:retention_days])
    rollup_days = Keyword.get(opts, :rollup_retention_days, config[:rollup_retention_days])

    batch_size = Keyword.get(opts, :batch_size, @prune_batch_size)

    %{
      results: prune_results(now, retention_days, batch_size),
      rollups: prune_rollups(now, rollup_days),
      events: prune_events(now, retention_days)
    }
  end

  defp prune_results(_now, days, _batch_size) when days in [nil, 0], do: 0

  defp prune_results(now, days, batch_size) do
    case watermark() do
      # Nothing is rolled up yet: deleting would lose data.
      nil ->
        0

      watermark ->
        # Only whole hours that are rolled up and won't be re-aggregated.
        retention_cutoff = now |> DateTime.add(-days, :day) |> Stats.floor_hour()
        rolled_up_until = DateTime.add(watermark, -@overlap_seconds, :second)
        cutoff = Enum.min([retention_cutoff, rolled_up_until], DateTime)

        Monitor
        |> select([m], m.id)
        |> Repo.all()
        |> Enum.reduce(0, &(&2 + delete_results(&1, cutoff, batch_size)))
    end
  end

  # Batched per monitor, so each statement is short and uses the
  # (monitor_id, checked_at) index.
  defp delete_results(monitor_id, cutoff, batch_size, total \\ 0) do
    ids =
      from r in CheckResult,
        where: r.monitor_id == ^monitor_id and r.checked_at < ^cutoff,
        select: r.id,
        limit: ^batch_size

    {count, _} = Repo.delete_all(from r in CheckResult, where: r.id in subquery(ids))

    if count == batch_size,
      do: delete_results(monitor_id, cutoff, batch_size, total + count),
      else: total + count
  end

  defp prune_events(_now, days) when days in [nil, 0], do: 0
  defp prune_events(now, days), do: Events.prune_events(DateTime.add(now, -days, :day))

  defp prune_rollups(_now, days) when days in [nil, 0], do: 0

  defp prune_rollups(now, days) do
    cutoff = now |> DateTime.add(-days, :day) |> Stats.floor_hour()
    {count, _} = Repo.delete_all(from h in HourlyStat, where: h.hour < ^cutoff)
    count
  end
end
