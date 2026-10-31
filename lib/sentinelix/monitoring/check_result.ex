defmodule Sentinelix.Monitoring.CheckResult do
  @moduledoc """
  The outcome of a single check run (a "heartbeat").

  Statuses:

    * `:up` and `:down` – the check succeeded or failed (and the monitor is,
      or went, down),
    * `:pending` – the check failed and is being retried,
    * `:maintenance` – checked during a maintenance window,
    * `:unreachable` – the check failed while the monitor's parent was down
      (see Dependencies in `Sentinelix.Monitoring.Worker`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.Monitoring.Monitor

  @statuses [:up, :down, :pending, :maintenance, :unreachable]
  @max_message_length 2_000

  schema "check_results" do
    field :status, Ecto.Enum, values: @statuses
    field :response_time_ms, :integer
    field :status_code, :integer
    field :message, :string
    field :checked_at, :utc_datetime_usec

    belongs_to :monitor, Monitor
  end

  @type t :: %__MODULE__{}
  @type status :: :up | :down | :pending | :maintenance | :unreachable

  @doc "All check result statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc false
  def changeset(check_result, attrs) do
    check_result
    |> cast(attrs, [:status, :response_time_ms, :status_code, :message, :checked_at])
    |> validate_required([:status, :checked_at])
    |> validate_number(:response_time_ms, greater_than_or_equal_to: 0)
    |> validate_number(:status_code, greater_than_or_equal_to: 0)
    |> update_change(:message, &truncate/1)
    |> assoc_constraint(:monitor)
  end

  # Error messages can be arbitrarily long (e.g. stack traces); keep the
  # stored message bounded instead of rejecting the result.
  defp truncate(message) when byte_size(message) > @max_message_length do
    String.slice(message, 0, @max_message_length - 1) <> "…"
  end

  defp truncate(message), do: message
end
