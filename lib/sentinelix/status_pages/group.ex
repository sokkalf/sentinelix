defmodule Sentinelix.StatusPages.Group do
  @moduledoc """
  A named, ordered group of monitors on a status page.

  A group is either

    * a **fixed list** (`selector` is `nil`): its monitors (`page_monitors`)
      in their positions, or
    * a **selector group**: its monitors (now *pinned*, in their positions)
      followed by every other monitor its `selector` (see
      `Sentinelix.Monitoring.Selector`) matches, by name. New and relabelled
      monitors join or leave the group automatically.

  Selectors of groups may use label and name terms but not `status`: a
  public page must not change its monitors as they go down. An empty
  selector is never stored (it would match every monitor and publish them
  all); a blank selector makes the group a fixed list, unless the
  changeset asks for a selector group with `kind: :selector`, which then
  requires one.

  `monitors` is not stored: `Sentinelix.StatusPages` fills it with the
  group's monitors in display order when it loads a page.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.Monitoring.Selector
  alias Sentinelix.StatusPages.{PageMonitor, StatusPage}

  @selector_options [allow: [:labels, :name]]

  schema "status_page_groups" do
    field :name, :string
    field :position, :integer, default: 0
    field :selector, :string
    # :fixed or :selector, see changeset/2; derived from `selector` when
    # not given.
    field :kind, Ecto.Enum, values: [:fixed, :selector], virtual: true
    field :monitors, {:array, :any}, virtual: true, default: []

    belongs_to :status_page, StatusPage

    has_many :page_monitors, PageMonitor, preload_order: [asc: :position, asc: :id]

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
  @type kind :: :fixed | :selector

  @doc """
  The options of `Sentinelix.Monitoring.Selector.parse/2` for group
  selectors: labels and names, no status.
  """
  @spec selector_options() :: keyword()
  def selector_options, do: @selector_options

  @doc """
  Whether the group is a fixed list or chooses its monitors by selector.
  """
  @spec kind(t()) :: kind()
  def kind(%__MODULE__{selector: nil}), do: :fixed
  def kind(%__MODULE__{}), do: :selector

  @doc """
  The group's parsed selector, or `nil` for a fixed list. A stored
  selector that doesn't parse (any more) or is empty is `nil` as well, so
  it never matches every monitor.
  """
  @spec parsed_selector(t()) :: Selector.t() | nil
  def parsed_selector(%__MODULE__{selector: text}) when is_binary(text) do
    case Selector.parse(text, @selector_options) do
      {:ok, selector} -> if Selector.empty?(selector), do: nil, else: selector
      {:error, _error} -> nil
    end
  end

  def parsed_selector(%__MODULE__{}), do: nil

  @doc """
  Casts the name, `kind` and selector. With `kind: :fixed` the selector is
  removed; with `kind: :selector` one is required. Without `kind`, a
  selector makes a selector group and a blank one a fixed list.
  """
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :kind, :selector])
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
    |> put_kind()
    |> validate_kind()
    |> assoc_constraint(:status_page)
  end

  defp put_kind(changeset) do
    case get_change(changeset, :kind) do
      nil ->
        kind = if get_field(changeset, :selector), do: :selector, else: :fixed
        put_change(changeset, :kind, kind)

      _kind ->
        changeset
    end
  end

  defp validate_kind(changeset) do
    case get_field(changeset, :kind) do
      :fixed ->
        put_change(changeset, :selector, nil)

      :selector ->
        changeset
        |> Selector.validate_selector(:selector, @selector_options)
        |> validate_required([:selector],
          message: "can't be blank: an empty selector would match every monitor"
        )
    end
  end
end
