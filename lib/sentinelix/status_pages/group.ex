defmodule Sentinelix.StatusPages.Group do
  @moduledoc """
  A named, ordered group of monitors on a status page.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.StatusPages.{PageMonitor, StatusPage}

  schema "status_page_groups" do
    field :name, :string
    field :position, :integer, default: 0

    belongs_to :status_page, StatusPage

    has_many :page_monitors, PageMonitor, preload_order: [asc: :position, asc: :id]

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name])
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
    |> assoc_constraint(:status_page)
  end
end
