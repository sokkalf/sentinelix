defmodule Sentinelix.Notifications.Supervisor do
  @moduledoc """
  Supervises the notification sending: a `Task.Supervisor` for the sends
  (`Sentinelix.Notifications.TaskSupervisor`) and the
  `Sentinelix.Notifications.Dispatcher`.

  ## Options

    * `:dispatcher` – start the dispatcher (default `true`; tests disable it
      and start their own)
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children =
      [{Task.Supervisor, name: Sentinelix.Notifications.TaskSupervisor}] ++
        if Keyword.get(opts, :dispatcher, true),
          do: [Sentinelix.Notifications.Dispatcher],
          else: []

    Supervisor.init(children, strategy: :one_for_one)
  end
end
