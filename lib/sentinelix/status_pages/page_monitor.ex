defmodule Sentinelix.StatusPages.PageMonitor do
  @moduledoc """
  A monitor shown in a status page group, at a position.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.Monitoring.Monitor
  alias Sentinelix.StatusPages.Group

  schema "status_page_monitors" do
    field :position, :integer, default: 0

    belongs_to :group, Group
    belongs_to :monitor, Monitor

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(page_monitor, attrs) do
    page_monitor
    |> cast(attrs, [:monitor_id])
    |> validate_required([:monitor_id])
    |> assoc_constraint(:group)
    |> assoc_constraint(:monitor)
    |> unique_constraint(:monitor_id,
      name: :status_page_monitors_group_id_monitor_id_index,
      message: "is already in this group"
    )
  end
end
