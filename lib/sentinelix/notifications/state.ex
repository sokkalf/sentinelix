defmodule Sentinelix.Notifications.State do
  @moduledoc """
  What has last been notified for a monitor: its `status` (`:up` or
  `:down`) and whether a `warning` is active.

  The monitoring workers re-broadcast transitions when they restart (e.g. a
  certificate warning is raised again after every restart, since the worker
  doesn't persist it). The dispatcher compares events against this
  persisted state so that monitor edits and app reboots don't re-send
  notifications.
  """

  use Ecto.Schema

  @primary_key {:monitor_id, :id, autogenerate: false}
  schema "notification_states" do
    field :status, Ecto.Enum, values: [:up, :down]
    field :warning, :boolean, default: false

    timestamps(type: :utc_datetime, inserted_at: false)
  end

  @type t :: %__MODULE__{}
end
