defmodule Sentinelix.Monitoring.Worker do
  @moduledoc """
  Runs the checks of a single monitor and holds its status state machine.

  Workers are started by `Sentinelix.Monitoring.Supervisor` (normally via
  the `Sentinelix.Monitoring.Manager`) and registered by monitor id.

  ## Scheduling

  The first check runs immediately after start. The next check is scheduled
  `interval_seconds` after the previous one started (or
  `retry_interval_seconds` while the monitor is `:pending`), plus a small
  random jitter so monitors don't run in lockstep. `check_now/2` runs a check
  right away. Only one check runs at a time.

  Each check runs in a task under the engine's `Task.Supervisor`; the worker
  stays responsive while it runs and kills it after the monitor's
  `timeout_ms` (recorded as `:down`). A check that raises or exits is
  recorded as `:down` too. Checks are killed outright (`:kill`) rather than
  shut down gracefully: a check that traps exits (e.g. while Postgrex
  connects) would otherwise block the worker and the task supervisor for
  the supervisor's shutdown timeout. Resources owned by the task (sockets,
  linked processes) are released when it dies.

  ## State machine

  The status starts as the status of the latest stored check result (so a
  restart doesn't produce spurious transitions), or `:pending` without one.

    * check `:up` → `:up` (retry counter reset).
    * check `:down` while not `:down` and fewer than `max_retries` retries
      used → `:pending` (retried after `retry_interval_seconds`).
    * check `:down` otherwise → `:down`.

  Maintenance and a parent that is down leave the status alone (see below).

  Every check is persisted with `Sentinelix.Monitoring.record_result/2`
  using the resulting status. When the status changes, the worker

    * opens an incident on entering `:down` and resolves the open incident
      on entering `:up`,
    * broadcasts `{:status_changed, monitor, old_status, new_status, result}`
      on the `"status_changes"` topic and the monitor's topic.

  Status changes include `:pending → :up` for a new monitor and `:up →
  :pending` while retrying; notifications should fire for any transition
  *to* `:down` and from `:down` to `:up`.

  A check result with `warning: true` (e.g. a certificate close to expiry)
  is stored as `:up`; entering and leaving the warning state broadcasts
  `{:warning_raised, monitor, result}` and `{:warning_cleared, monitor,
  result}` on the same topics. The warning state is not persisted, so a
  restarted worker raises an active warning again.

  ## Passive checks (push monitors)

  A check whose module implements `c:Sentinelix.Checks.Check.passive?/0`
  returning `true` (see `Sentinelix.Checks.Push`) doesn't probe anything.
  Results are delivered to the worker with `push/3` instead and go through
  the same state machine (retries, incidents, events, maintenance) as the
  results of active checks. The check itself only runs when no push arrived
  in time:

    * After start and after every push the check is scheduled
      `interval_seconds` plus `push_grace_seconds` later; each push
      reschedules it.
    * When it runs, it reports `:down` (no push received). Further checks
      follow the normal schedule (`retry_interval_seconds` while `:pending`,
      `interval_seconds` otherwise) until the next push.
    * `check_now/2` does nothing: there is nothing to probe, and a push
      that is merely not overdue yet must not be reported as missing.

  ## Maintenance

  If the engine is configured with a `:maintenance` module, its
  `active?(monitor, now)` is consulted after each check. While it returns
  `true` the result is recorded as `:maintenance`, the status, retries and
  incidents are left untouched and no events are broadcast; normal
  evaluation resumes with the next check after the window. The application
  configures `Sentinelix.Maintenance` (maintenance windows) as that module.

  ## Dependencies

  A monitor with a parent (`parent_id`, e.g. the ping monitor of its host)
  doesn't alert while the parent is down: the parent's incident covers it.

  Every worker publishes whether its latest check succeeded (`reachable`,
  the raw result, whatever status was recorded) as its value in the
  engine's `Registry`, and broadcasts `{:parent_checked, id, reachable}` on
  `dependents_topic/2` after every check. Children read their parent's
  value from the registry when a check completes (no call into the parent,
  so no deadlocks and no waiting on a parent's running check) and
  subscribe to its topic to react promptly:

    * A failed check while the parent's latest check failed too is
      recorded as `:unreachable`. Like maintenance, the status, retries and
      incidents are left untouched and no events are broadcast, so nothing
      is notified. The parent "is down" as soon as one of its checks fails,
      while it is still retrying, in maintenance or unreachable itself
      (so suppression is transitive along a chain of parents).
    * The race of a child failing before its parent's next check: when a
      failure would take the child to `:down` (all retries used) while its
      parent looks up, the child asks the parent to check now and records
      the failure as `:pending` instead. Once the parent's result arrives
      the child checks again: unreachable if the parent failed, down
      otherwise. This happens once per failure streak; if the parent
      doesn't answer, the next scheduled retry decides.
    * When the parent's check succeeds again, children whose latest result
      was unreachable are re-checked right away, before anything is
      notified. A child that is still failing then goes through its retries
      and goes down (and alerts) like any other monitor.

  A parent without a running worker (paused, or not loaded yet) doesn't
  suppress anything. Passive (push) children record missed or failed
  pushes as unreachable too, but have nothing to re-check: their deadline
  decides, and they don't ask the parent to confirm.

  ## Telemetry

    * `[:sentinelix, :check, :start]` – measurements `%{system_time:,
      monotonic_time:}`, metadata `%{monitor_id:, monitor_type:}`.
    * `[:sentinelix, :check, :stop]` – measurements `%{duration:}` (native
      time units) and `%{response_time_ms:}`, metadata `%{monitor_id:,
      monitor_type:, result:, status:, error:, meta:}` where `result` is the
      check's `:up`/`:down`, `status` the recorded status and `error` is
      `nil`, `:timeout` or `:crash`.
    * `[:sentinelix, :monitor, :status_changed]` – measurements `%{count: 1}`,
      metadata `%{monitor_id:, monitor_type:, from:, to:}`.
  """

  use GenServer, restart: :transient

  require Logger

  alias Phoenix.PubSub
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{CheckResult, Monitor}
  alias Sentinelix.Monitoring.Supervisor, as: Engine

  @type status :: :pending | :up | :down

  @pubsub Sentinelix.PubSub

  defstruct [
    :monitor,
    :check,
    :config,
    :incident,
    :timer,
    :task,
    :task_timer,
    :started_at,
    :next_check_at,
    passive: false,
    status: :pending,
    retries: 0,
    warning: false,
    # The latest result was recorded as unreachable.
    unreachable: false,
    # Waiting for the parent's check before going down (see Dependencies).
    confirming: false,
    # The parent has been asked to confirm during this failure streak.
    confirmed: false
  ]

  ## API

  def start_link(opts) do
    monitor = Keyword.fetch!(opts, :monitor)
    config = Keyword.fetch!(opts, :config)
    name = {:via, Registry, {Engine.registry(config.engine), monitor.id}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs a check of the monitor now (unless one is already running).
  """
  @spec check_now(Monitor.t() | pos_integer(), Engine.engine()) :: :ok | {:error, :not_running}
  def check_now(monitor, engine \\ Engine) do
    case Engine.whereis(monitor, engine) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, :check_now)
    end
  end

  @doc """
  Delivers the result of a passive check (e.g. a received push) to the
  monitor's worker, which records and evaluates it like a check result.

  Returns the stored check result (`nil` if it could not be stored). Returns
  `{:error, :not_running}` if the monitor has no worker and
  `{:error, :not_passive}` if its check is not passive.
  """
  @spec push(Monitor.t() | pos_integer(), Sentinelix.Checks.Check.result(), Engine.engine()) ::
          {:ok, CheckResult.t() | nil} | {:error, :not_running | :not_passive}
  def push(monitor, {status, details} = result, engine \\ Engine)
      when status in [:up, :down] and is_map(details) do
    case Engine.whereis(monitor, engine) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:push, result})
    end
  catch
    # The worker stopped (e.g. the monitor was disabled) during the call.
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] -> {:error, :not_running}
    :exit, {{:shutdown, _}, _} -> {:error, :not_running}
  end

  @doc """
  Returns the runtime state of a monitor's worker: `:status`, `:retries`,
  `:warning`, `:unreachable` (whether the latest result was unreachable),
  `:checking` (whether a check is running) and `:next_check_at`.
  """
  @spec info(Monitor.t() | pos_integer(), Engine.engine()) :: map() | nil
  def info(monitor, engine \\ Engine) do
    case Engine.whereis(monitor, engine) do
      nil -> nil
      pid -> GenServer.call(pid, :info)
    end
  end

  @doc """
  Whether the latest check of a monitor's worker succeeded, as published
  in the engine's registry: `true`, `false`, or `nil` if the monitor has no
  worker or nothing is known yet. Doesn't call the worker.
  """
  @spec reachable?(Monitor.t() | pos_integer(), Engine.engine()) :: boolean() | nil
  def reachable?(monitor, engine \\ Engine) do
    case Engine.lookup(monitor, engine) do
      {_pid, %{reachable: reachable}} -> reachable
      _ -> nil
    end
  end

  @doc """
  The topic a worker broadcasts `{:parent_checked, id, reachable}` on after
  every check, for its children (see Dependencies).
  """
  @spec dependents_topic(Engine.engine(), pos_integer()) :: String.t()
  def dependents_topic(engine, id), do: "engine:#{inspect(engine)}:dependents:#{id}"

  ## Callbacks

  @impl true
  def init(opts) do
    check = Keyword.fetch!(opts, :check)

    state = %__MODULE__{
      monitor: Keyword.fetch!(opts, :monitor),
      check: check,
      config: Keyword.fetch!(opts, :config),
      passive: passive?(check)
    }

    # Finish recording a check that is being processed before shutting down.
    Process.flag(:trap_exit, true)
    Logger.metadata(monitor_id: state.monitor.id)

    if parent_id = state.monitor.parent_id do
      :ok = PubSub.subscribe(@pubsub, dependents_topic(state.config.engine, parent_id))
    end

    {:ok, state, {:continue, :restore}}
  end

  @impl true
  def handle_continue(:restore, %{monitor: monitor} = state) do
    latest = Monitoring.get_latest_result(monitor)

    status =
      case latest do
        %CheckResult{status: status} when status in [:up, :down] -> status
        _ -> :pending
      end

    state = %{
      state
      | status: status,
        unreachable: match?(%CheckResult{status: :unreachable}, latest),
        incident: Monitoring.get_open_incident(monitor)
    }

    # Until the first check: whether the latest stored one succeeded (not
    # known for a maintenance result).
    state =
      put_reachable(
        state,
        case latest do
          %CheckResult{status: :up} -> true
          %CheckResult{status: status} when status in [:down, :pending, :unreachable] -> false
          _ -> nil
        end
      )

    if state.passive,
      do: {:noreply, schedule_deadline(state)},
      else: {:noreply, start_check(state)}
  end

  @impl true
  def handle_cast(:check_now, %{passive: true} = state), do: {:noreply, state}
  def handle_cast(:check_now, state), do: {:noreply, start_check(state)}

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      status: state.status,
      retries: state.retries,
      warning: state.warning,
      unreachable: state.unreachable,
      checking: state.task != nil,
      next_check_at: state.next_check_at
    }

    {:reply, info, state}
  end

  def handle_call({:push, _result}, _from, %{passive: false} = state),
    do: {:reply, {:error, :not_passive}, state}

  def handle_call({:push, {result, details}}, _from, state) do
    # A push supersedes a "no push received" check that is running right now.
    state = cancel_check(state)
    cancel_timer(state.timer)
    emit_start(state)
    state = %{state | timer: nil, started_at: System.monotonic_time()}

    case finish(state, {result, Map.put_new(details, :response_time_ms, nil)}, nil) do
      {:ok, state, check_result} -> {:reply, {:ok, check_result}, schedule_deadline(state)}
      :stop -> {:stop, :normal, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_info(:check, state), do: {:noreply, start_check(%{state | timer: nil})}

  # The parent checked: check again if waiting for it to confirm a failure,
  # or if the parent is back while this monitor was unreachable.
  def handle_info({:parent_checked, id, reachable}, %{monitor: %{parent_id: id}} = state) do
    cond do
      state.confirming -> {:noreply, start_check(%{state | confirming: false})}
      reachable and state.unreachable and not state.passive -> {:noreply, start_check(state)}
      true -> {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    complete(state, normalize(result), nil)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    message = "Check crashed: " <> crash_reason(reason)
    complete(state, {:down, %{message: message}}, :crash)
  end

  def handle_info({:check_timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    kill_task(task)
    message = "Timed out after #{state.monitor.timeout_ms} ms"
    complete(state, {:down, %{message: message}}, :timeout)
  end

  # Late replies of killed tasks and timeouts of finished ones.
  def handle_info({:check_timeout, _ref}, state), do: {:noreply, state}
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("#{inspect(__MODULE__)} ignoring unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  ## Running checks

  defp start_check(%{task: %Task{}} = state), do: state

  defp start_check(%{monitor: monitor, check: check} = state) do
    cancel_timer(state.timer)
    emit_start(state)

    task =
      Task.Supervisor.async_nolink(state.config.task_supervisor, fn -> check.run(monitor) end)

    task_timer = Process.send_after(self(), {:check_timeout, task.ref}, monitor.timeout_ms)

    # Whatever started this check, it decides instead of a confirmation by
    # the parent that is still awaited.
    %{
      state
      | task: task,
        task_timer: task_timer,
        confirming: false,
        timer: nil,
        next_check_at: nil,
        started_at: System.monotonic_time()
    }
  end

  defp cancel_check(%{task: nil} = state), do: state

  defp cancel_check(%{task: task} = state) do
    kill_task(task)
    cancel_timer(state.task_timer)
    %{state | task: nil, task_timer: nil}
  end

  defp kill_task(%Task{pid: pid, ref: ref}) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
  end

  defp passive?(check) do
    Code.ensure_loaded?(check) and function_exported?(check, :passive?, 0) and check.passive?()
  end

  defp crash_reason({exception, stacktrace})
       when is_exception(exception) and is_list(stacktrace),
       do: Exception.format_banner(:error, exception)

  defp crash_reason(reason), do: Exception.format_exit(reason)

  defp normalize({status, details}) when status in [:up, :down] and is_map(details),
    do: {status, details}

  defp normalize(other),
    do: {:down, %{message: "Check returned an invalid result: #{inspect(other)}"}}

  defp complete(state, result, error) do
    cancel_timer(state.task_timer)
    state = %{state | task: nil, task_timer: nil}

    case finish(state, result, error) do
      {:ok, state, _check_result} ->
        {:noreply, schedule(state, System.monotonic_time() - state.started_at)}

      :stop ->
        {:stop, :normal, state}
    end
  end

  # Records a check result, applies the state machine and emits telemetry.
  defp finish(state, {result, details}, error) do
    duration = System.monotonic_time() - state.started_at

    details =
      Map.put_new_lazy(details, :response_time_ms, fn ->
        System.convert_time_unit(duration, :native, :millisecond)
      end)

    # Published before the result is recorded (and broadcast), so whoever
    # reacts to the result already sees it.
    state = put_reachable(state, result == :up)

    case evaluate(state, result, details) do
      {:ok, state, status, check_result} ->
        state = %{
          state
          | unreachable: status == :unreachable,
            confirmed: state.confirmed and result != :up
        }

        notify_dependents(state, result == :up)
        emit_stop(state, duration, result, status, error, details)
        {:ok, state, check_result}

      :stop ->
        :stop
    end
  end

  # Decides the status to record and records it, see the moduledoc.
  defp evaluate(state, result, details) do
    cond do
      maintenance?(state) ->
        record(state, :maintenance, details, &keep_state/2)

      result == :down and parent_down?(state) ->
        record(state, :unreachable, details, &keep_state/2)

      result == :down and confirm_with_parent?(state) ->
        state = ask_parent(state)
        record(state, :pending, details, &apply_transition(&1, &2, :pending, details))

      true ->
        {status, retries} = next_status(state, result)
        state = %{state | retries: retries}
        record(state, status, details, &apply_transition(&1, &2, status, details))
    end
  end

  defp keep_state(state, _result), do: state

  ## Dependencies

  # Publishes whether the latest check succeeded for the children (see
  # Dependencies in the moduledoc).
  defp put_reachable(%{monitor: monitor, config: config} = state, reachable) do
    value = %{reachable: reachable, passive: state.passive}
    _ = Registry.update_value(Engine.registry(config.engine), monitor.id, fn _ -> value end)
    state
  end

  defp notify_dependents(%{monitor: monitor, config: config}, reachable) do
    PubSub.broadcast(
      @pubsub,
      dependents_topic(config.engine, monitor.id),
      {:parent_checked, monitor.id, reachable}
    )
  end

  defp parent_down?(%{monitor: %{parent_id: nil}}), do: false

  defp parent_down?(%{monitor: %{parent_id: parent_id}, config: config}),
    do: reachable?(parent_id, config.engine) == false

  # Whether to ask the parent before this failure takes the monitor down:
  # once per failure streak, if the parent looks up and can be checked.
  defp confirm_with_parent?(%{monitor: %{parent_id: nil}}), do: false
  defp confirm_with_parent?(%{passive: true}), do: false
  defp confirm_with_parent?(%{confirmed: true}), do: false
  defp confirm_with_parent?(%{status: :down}), do: false

  defp confirm_with_parent?(%{monitor: %{parent_id: parent_id}, config: config} = state) do
    next_status(state, :down) == {:down, 0} and
      match?({_pid, %{reachable: true, passive: false}}, Engine.lookup(parent_id, config.engine))
  end

  defp ask_parent(%{monitor: %{parent_id: parent_id}, config: config} = state) do
    case check_now(parent_id, config.engine) do
      :ok -> %{state | confirming: true, confirmed: true}
      {:error, :not_running} -> %{state | confirmed: true}
    end
  end

  defp next_status(_state, :up), do: {:up, 0}

  defp next_status(%{status: status, retries: retries, monitor: monitor}, :down)
       when status != :down and retries < monitor.max_retries,
       do: {:pending, retries + 1}

  defp next_status(_state, :down), do: {:down, 0}

  defp record(state, status, details, then) do
    attrs = %{
      status: status,
      response_time_ms: details[:response_time_ms],
      status_code: details[:status_code],
      message: details[:message]
    }

    case Monitoring.record_result(state.monitor, attrs) do
      {:ok, result} ->
        {:ok, then.(state, result), status, result}

      {:error, changeset} ->
        if Monitoring.get_monitor(state.monitor.id) do
          Logger.error("Could not record check result: #{inspect(changeset.errors)}")
          {:ok, state, status, nil}
        else
          # The monitor was deleted while the check was running.
          :stop
        end
    end
  end

  defp apply_transition(%{status: old} = state, result, new, details) do
    state =
      state
      |> update_incident(new, result)
      |> Map.put(:status, new)

    if old != new do
      :telemetry.execute(
        [:sentinelix, :monitor, :status_changed],
        %{count: 1},
        %{monitor_id: state.monitor.id, monitor_type: state.monitor.type, from: old, to: new}
      )

      Monitoring.broadcast_status_event(
        state.monitor,
        {:status_changed, state.monitor, old, new, result}
      )
    end

    update_warning(state, new == :up and details[:warning] == true, result)
  end

  defp update_incident(%{incident: nil} = state, :down, result) do
    attrs = %{from_status: state.status, to_status: :down, message: result.message}

    case Monitoring.open_incident(state.monitor, attrs) do
      {:ok, incident} ->
        %{state | incident: incident}

      {:error, changeset} ->
        Logger.error("Could not open incident: #{inspect(changeset.errors)}")
        %{state | incident: Monitoring.get_open_incident(state.monitor)}
    end
  end

  defp update_incident(%{incident: %{} = incident} = state, :up, result) do
    case Monitoring.resolve_incident(incident, resolved_at: result.checked_at) do
      {:ok, _incident} ->
        %{state | incident: nil}

      {:error, :already_resolved} ->
        %{state | incident: nil}

      {:error, changeset} ->
        Logger.error("Could not resolve incident: #{inspect(changeset.errors)}")
        state
    end
  end

  defp update_incident(state, _status, _result), do: state

  defp update_warning(%{warning: same} = state, same, _result), do: state

  defp update_warning(%{warning: false} = state, true, result) do
    Monitoring.broadcast_status_event(state.monitor, {:warning_raised, state.monitor, result})
    %{state | warning: true}
  end

  defp update_warning(%{warning: true} = state, false, result) do
    # Going down supersedes the warning; only an up result clears it.
    if result.status == :up do
      Monitoring.broadcast_status_event(state.monitor, {:warning_cleared, state.monitor, result})
    end

    %{state | warning: false}
  end

  defp maintenance?(%{config: %{maintenance: nil}}), do: false

  defp maintenance?(%{config: %{maintenance: module}, monitor: monitor}),
    do: module.active?(monitor, DateTime.utc_now())

  defp emit_start(%{monitor: monitor}) do
    :telemetry.execute(
      [:sentinelix, :check, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{monitor_id: monitor.id, monitor_type: monitor.type}
    )
  end

  defp emit_stop(state, duration, result, status, error, details) do
    :telemetry.execute(
      [:sentinelix, :check, :stop],
      %{duration: duration, response_time_ms: details[:response_time_ms]},
      %{
        monitor_id: state.monitor.id,
        monitor_type: state.monitor.type,
        result: result,
        status: status,
        error: error,
        meta: Map.get(details, :meta, %{})
      }
    )
  end

  ## Scheduling

  defp schedule(%{monitor: monitor} = state, elapsed) do
    interval_s =
      if state.status == :pending,
        do: monitor.retry_interval_seconds,
        else: monitor.interval_seconds

    interval_ms = interval_s * 1000
    elapsed_ms = System.convert_time_unit(elapsed, :native, :millisecond)
    delay = max(interval_ms - elapsed_ms, 0) + jitter(interval_ms, state.config.jitter)

    %{
      state
      | timer: Process.send_after(self(), :check, delay),
        next_check_at: DateTime.add(DateTime.utc_now(), delay, :millisecond)
    }
  end

  # Passive checks: run the check (no push received) if no push arrives
  # within the interval plus the grace period.
  defp schedule_deadline(%{monitor: monitor} = state) do
    grace_s = (monitor.settings && monitor.settings.push_grace_seconds) || 0
    delay = (monitor.interval_seconds + grace_s) * 1000

    %{
      state
      | timer: Process.send_after(self(), :check, delay),
        next_check_at: DateTime.add(DateTime.utc_now(), delay, :millisecond)
    }
  end

  defp jitter(interval_ms, fraction) when is_number(fraction) and fraction > 0 do
    case trunc(interval_ms * fraction) do
      0 -> 0
      max -> :rand.uniform(max + 1) - 1
    end
  end

  defp jitter(_interval_ms, _fraction), do: 0

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end
end
