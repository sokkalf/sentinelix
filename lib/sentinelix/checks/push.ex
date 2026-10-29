defmodule Sentinelix.Checks.Push do
  @moduledoc """
  Push (heartbeat) check.

  A passive check: the monitored service (a cron job, a backup script, …)
  reports in by calling the push URL of the monitor,

      GET|POST /api/push/<push_token>?status=up|down&msg=...&ping=<ms>

  and every push is recorded through the monitor's worker (see
  `Sentinelix.Monitoring.receive_push/2`). The monitor goes down when no
  push arrived within `interval_seconds` plus `push_grace_seconds`: only
  then does the worker call `run/1`, which reports the missing push. See
  "Passive checks" in `Sentinelix.Monitoring.Worker`.
  """

  @behaviour Sentinelix.Checks.Check

  alias Sentinelix.Monitoring.Monitor

  @impl true
  def passive?, do: true

  @impl true
  def run(%Monitor{} = monitor) do
    {:down,
     %{
       response_time_ms: nil,
       message: "No push received within #{deadline_seconds(monitor)} s"
     }}
  end

  @doc """
  Seconds after a push (or the start of the worker) until a missing push
  counts as down: the interval plus the grace period.
  """
  @spec deadline_seconds(Monitor.t()) :: non_neg_integer()
  def deadline_seconds(%Monitor{interval_seconds: interval, settings: settings}) do
    interval + ((settings && settings.push_grace_seconds) || 0)
  end
end
