defmodule Sentinelix.Monitoring.Incident do
  @moduledoc """
  A period during which a monitor was in a non-up state, recorded on status
  transitions. An incident is *open* while `resolved_at` is `nil`; a monitor
  has at most one open incident at a time.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.Monitoring.{CheckResult, Monitor}

  @statuses CheckResult.statuses()

  schema "incidents" do
    field :from_status, Ecto.Enum, values: @statuses
    field :to_status, Ecto.Enum, values: @statuses
    field :started_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :message, :string

    belongs_to :monitor, Monitor

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def open_changeset(incident, attrs) do
    incident
    |> cast(attrs, [:from_status, :to_status, :started_at, :message])
    |> validate_required([:from_status, :to_status, :started_at])
    |> assoc_constraint(:monitor)
    |> unique_constraint(:monitor_id,
      name: :incidents_one_open_per_monitor_index,
      message: "already has an open incident"
    )
  end

  @doc false
  def resolve_changeset(incident, attrs) do
    incident
    |> cast(attrs, [:resolved_at])
    |> validate_required([:resolved_at])
    |> validate_resolved_after_started()
    |> check_constraint(:resolved_at, name: :resolved_after_started)
  end

  defp validate_resolved_after_started(changeset) do
    started_at = get_field(changeset, :started_at)
    resolved_at = get_field(changeset, :resolved_at)

    if started_at && resolved_at && DateTime.before?(resolved_at, started_at) do
      add_error(changeset, :resolved_at, "must not be before the incident started")
    else
      changeset
    end
  end
end
