defmodule Sentinelix.SavedViews.SavedView do
  @moduledoc """
  A saved view: a name for a `Sentinelix.Monitoring.View` (a stored,
  named dashboard URL), see `Sentinelix.SavedViews`.

    * `params` – the view as URL parameters
      (`Sentinelix.Monitoring.View.to_params/1`, string keys and values),
      read back with `Sentinelix.Monitoring.View.from_params/1`. Storing the
      parameters rather than a column per setting means new view settings
      need no migration, and a stored selector that no longer parses still
      loads (and shows its error).
    * `slug` – unique and stable: derived from the name when the view is
      created and kept when it is renamed, so links to it keep working.
    * `visibility` – who sees the view: `:personal` (only the owner),
      `:shared` (all users) or `:groups` (users in any of `groups`, OIDC
      groups). Only the owner can change or delete a view.
    * `position` – the order of the owner's views.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.Accounts.User

  @visibilities [:personal, :shared, :groups]
  @max_name_length 80
  @max_params 20
  @max_param_length 4_000

  schema "saved_views" do
    field :name, :string
    field :slug, :string
    field :params, :map, default: %{}
    field :visibility, Ecto.Enum, values: @visibilities, default: :personal
    field :groups, {:array, :string}, default: []
    field :position, :integer, default: 0

    belongs_to :owner, User

    timestamps(type: :utc_datetime)
  end

  @type visibility :: :personal | :shared | :groups
  @type t :: %__MODULE__{}

  @doc "The visibilities: `:personal`, `:shared` and `:groups`."
  @spec visibilities() :: [visibility()]
  def visibilities, do: @visibilities

  @doc """
  Changes the name, visibility and groups. `user_groups` are the groups of
  the user making the change: groups the view doesn't have yet must be
  among them (groups it has can be kept). Groups are dropped unless the
  visibility is `:groups`, which needs at least one.
  """
  @spec changeset(t(), map(), [String.t()]) :: Ecto.Changeset.t()
  def changeset(view, attrs, user_groups) do
    view
    |> cast(attrs, [:name, :visibility, :groups])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :visibility])
    |> validate_length(:name, max: @max_name_length)
    |> update_change(:groups, &normalize_groups/1)
    |> put_groups()
    |> validate_groups(view.groups, user_groups)
  end

  @doc """
  Changes the stored view parameters: string values, as
  `Sentinelix.Monitoring.View.to_params/1` gives them (atom or string keys).
  """
  @spec params_changeset(t() | Ecto.Changeset.t(), Enumerable.t()) :: Ecto.Changeset.t()
  def params_changeset(view, params) do
    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)

    view
    |> change(params: params)
    |> validate_change(:params, fn :params, params -> validate_params(params) end)
  end

  @doc false
  def slug_changeset(changeset, slug) do
    changeset
    |> put_change(:slug, slug)
    |> unique_constraint(:slug)
  end

  defp validate_params(params) do
    cond do
      map_size(params) > @max_params ->
        [params: "has too many settings"]

      not Enum.all?(params, fn {_key, value} -> is_binary(value) end) ->
        [params: "is invalid"]

      Enum.any?(params, fn {_key, value} -> String.length(value) > @max_param_length end) ->
        [params: "is too long"]

      true ->
        []
    end
  end

  defp normalize_groups(groups) do
    groups
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp put_groups(changeset) do
    case get_field(changeset, :visibility) do
      :groups ->
        if get_field(changeset, :groups) == [],
          do: add_error(changeset, :groups, "pick at least one group"),
          else: changeset

      _other ->
        put_change(changeset, :groups, [])
    end
  end

  defp validate_groups(changeset, current, user_groups) do
    validate_change(changeset, :groups, fn :groups, groups ->
      case (groups -- current) -- user_groups do
        [] -> []
        _others -> [groups: "you can only choose groups you are a member of"]
      end
    end)
  end
end
