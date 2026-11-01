defmodule Sentinelix.Monitoring.MonitorEvent do
  @moduledoc """
  An event an external system posted to a monitor (see
  `Sentinelix.Monitoring.Events`), shown in the monitor's timeline.

  Severities:

    * `:info` – logged only,
    * `:warning` – raised the warning `key` (`""` without a key),
    * `:ok` – cleared the warning `key`.

  `metadata` holds the extra fields of the request (string keys), e.g.
  `action`, `role`, `cluster` or `host`.
  """

  use Ecto.Schema

  alias Sentinelix.Monitoring.Monitor

  @severities [:info, :warning, :ok]

  schema "monitor_events" do
    field :occurred_at, :utc_datetime_usec
    field :severity, Ecto.Enum, values: @severities
    field :key, :string
    field :title, :string
    field :message, :string
    field :metadata, :map, default: %{}

    belongs_to :monitor, Monitor

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
  @type severity :: :info | :warning | :ok

  @doc "All event severities."
  @spec severities() :: [severity()]
  def severities, do: @severities
end
