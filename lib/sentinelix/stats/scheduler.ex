defmodule Sentinelix.Stats.Scheduler do
  @moduledoc """
  Periodically runs `Sentinelix.Stats.Rollup.run/1` and
  `Sentinelix.Stats.Rollup.prune/1`.

  A plain GenServer with `Process.send_after/3` rather than a job queue
  such as Oban: both jobs are idempotent (rollups are recomputed and
  upserted, pruning deletes by cutoff), so a missed or duplicated run (a
  restart, several nodes) is harmless and needs no persistence, locking or
  retries. A failed run is logged and retried on the next tick.

  ## Options

  From `config :sentinelix, Sentinelix.Stats.Scheduler` (the test config
  disables it):

    * `:enabled` – start the scheduler (default `true`),
    * `:rollup_interval` – ms between rollups (default 5 minutes),
    * `:prune_interval` – ms between prunes (default 1 hour),
    * `:initial_delay` – ms before the first run after boot (default 10 s),
    * `:name` – process name (default `#{inspect(__MODULE__)}`).
  """

  use GenServer

  require Logger

  alias Sentinelix.Stats.Rollup

  @defaults [
    rollup_interval: :timer.minutes(5),
    prune_interval: :timer.hours(1),
    initial_delay: :timer.seconds(10)
  ]

  @doc """
  Child spec for the application supervisor; `:ignore` when disabled.
  """
  def start_link(opts) do
    opts = Keyword.merge(@defaults, opts)

    if Keyword.get(opts, :enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl true
  def init(opts) do
    state = Map.new(Keyword.take(opts, [:rollup_interval, :prune_interval]))
    Process.send_after(self(), :rollup, opts[:initial_delay])
    Process.send_after(self(), :prune, opts[:initial_delay])
    {:ok, state}
  end

  @impl true
  def handle_info(:rollup, state) do
    safely(:rollup, fn -> {:ok, _count} = Rollup.run() end)
    Process.send_after(self(), :rollup, state.rollup_interval)
    {:noreply, state}
  end

  def handle_info(:prune, state) do
    safely(:prune, fn ->
      # Prune only what the rollups already cover.
      {:ok, _count} = Rollup.run()
      deleted = Rollup.prune()

      if deleted.results + deleted.rollups > 0 do
        Logger.info(
          "Pruned #{deleted.results} check results and #{deleted.rollups} hourly rollups"
        )
      end
    end)

    Process.send_after(self(), :prune, state.prune_interval)
    {:noreply, state}
  end

  # A failing run (e.g. the database being unavailable) must not crash the
  # scheduler; the next tick tries again.
  defp safely(job, fun) do
    fun.()
  rescue
    error -> Logger.error("Stats #{job} failed: " <> Exception.message(error))
  catch
    kind, reason -> Logger.error("Stats #{job} failed: #{inspect({kind, reason})}")
  end
end
