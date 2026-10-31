defmodule Sentinelix.Notifications.Dispatcher do
  @moduledoc """
  Sends notifications for the monitoring engine's status events.

  Subscribes to `"status_changes"` (see
  `Sentinelix.Monitoring.subscribe_status_changes/0`) and notifies the
  enabled channels of the monitor, attached to it or routed by selector
  (`Sentinelix.Notifications.list_notified_channels/1`, resolved when the
  event is handled from the monitor's current labels):

    * `{:status_changed, m, _old, :down, r}` → `:down`, unless `:down` was
      already the last notified status;
    * `{:status_changed, m, old, :up, r}` → `:up` (recovery) if `:down` is
      the last notified status (or, without a notified status, if `old` is
      `:down`). `pending → up` of a new monitor isn't notified, and neither
      are transitions to `:pending` (retries);
    * `{:warning_raised, m, r}` → `:warning`, unless a warning was already
      notified;
    * `{:warning_cleared, m, r}` → `:warning_cleared` if a warning was
      notified.

  The last notified status and warning are persisted per monitor
  (`Sentinelix.Notifications.State`). Workers start from the last stored
  check result, but they don't persist their warning flag (so every restart
  re-raises an active warning) and a `:maintenance` or `:unreachable` result
  makes them start as `:pending`. Comparing against the persisted state keeps restarts (app
  reboots, monitor edits) from re-sending notifications. A recovery clears
  the notified warning: a warning still present after an outage is notified
  again.

  Each channel is sent to in its own task under the notifications
  `Task.Supervisor`, with retries (`Sentinelix.Notifications.Delivery`).
  Errors while handling an event are logged and never crash the dispatcher.
  """

  use GenServer

  require Logger

  alias Sentinelix.{Monitoring, Notifications}
  alias Sentinelix.Notifications.{Delivery, Event}

  @doc """
  Starts the dispatcher.

  ## Options

    * `:name` – registered name (default `#{inspect(__MODULE__)}`, `nil` for none)
    * `:task_supervisor` – the `Task.Supervisor` sends run under
      (default `Sentinelix.Notifications.TaskSupervisor`)
    * `:delivery` – options for `Delivery.deliver_with_retry/3`
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    :ok = Monitoring.subscribe_status_changes()

    {:ok,
     %{
       task_supervisor:
         Keyword.get(opts, :task_supervisor, Sentinelix.Notifications.TaskSupervisor),
       delivery: Keyword.get(opts, :delivery, [])
     }}
  end

  @impl true
  def handle_info(message, state) do
    handle_event(message, state)
    {:noreply, state}
  rescue
    exception ->
      Logger.error(
        "#{inspect(__MODULE__)} failed to handle #{inspect(elem_name(message))}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:noreply, state}
  catch
    kind, reason ->
      Logger.error(
        "#{inspect(__MODULE__)} failed to handle #{inspect(elem_name(message))}: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:noreply, state}
  end

  defp elem_name(message) when is_tuple(message) and tuple_size(message) > 0, do: elem(message, 0)
  defp elem_name(message), do: message

  defp handle_event({:status_changed, monitor, old, new, result}, state) do
    notified = Notifications.get_state(monitor)

    case {new, notified.status} do
      {:down, :down} ->
        :ok

      {:down, _} ->
        {:ok, _} = Notifications.put_state(notified, %{status: :down})
        dispatch(Event.new(:down, monitor, result), state)

      {:up, last} ->
        {:ok, _} = Notifications.put_state(notified, %{status: :up, warning: false})

        if last == :down or (last == nil and old == :down),
          do: dispatch(Event.new(:up, monitor, result), state)

      _pending ->
        :ok
    end
  end

  defp handle_event({:warning_raised, monitor, result}, state) do
    case Notifications.get_state(monitor) do
      %{warning: true} ->
        :ok

      notified ->
        {:ok, _} = Notifications.put_state(notified, %{warning: true})
        dispatch(Event.new(:warning, monitor, result), state)
    end
  end

  defp handle_event({:warning_cleared, monitor, result}, state) do
    case Notifications.get_state(monitor) do
      %{warning: true} = notified ->
        {:ok, _} = Notifications.put_state(notified, %{warning: false})
        dispatch(Event.new(:warning_cleared, monitor, result), state)

      _notified ->
        :ok
    end
  end

  defp handle_event(_message, _state), do: :ok

  defp dispatch(%Event{} = event, state) do
    for channel <- Notifications.list_notified_channels(event.monitor_id) do
      {:ok, _pid} =
        Task.Supervisor.start_child(state.task_supervisor, fn ->
          Logger.metadata(monitor_id: event.monitor_id)
          Delivery.deliver_with_retry(channel, event, state.delivery)
        end)
    end

    :ok
  end
end
