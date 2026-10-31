defmodule Sentinelix.DisplayTokens.DisplayToken do
  @moduledoc """
  A display token: read-only access to some saved views for a wall or
  kiosk display, without a user session (see `Sentinelix.DisplayTokens`).

    * `token_hash` – the SHA-256 of the token. The token itself is shown
      once, when it's created, and never stored.
    * `user` – who created it. The display shows only the token's views
      that the creator sees (now, not when the token was made); deleting
      the creator deletes their tokens.
    * `token_views` – the views, in the order the display rotates through
      them (`Sentinelix.DisplayTokens.DisplayTokenView`).
    * `name` – optional, to tell tokens apart ("Office TV").
    * `rotate_seconds` – seconds between views, `nil` to show the first
      view only.
    * `expires_at` – after which the token no longer works, `nil` for
      never.
    * `last_used_at` – when a display last loaded or checked the token
      (updated at most once a minute).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.Accounts.User
  alias Sentinelix.DisplayTokens.DisplayTokenView

  @max_name_length 80
  @max_views 20
  @rotate_range 5..3600
  @expiry_days [1, 7, 30, 90, 365]

  schema "display_tokens" do
    field :name, :string
    field :token_hash, :binary, redact: true
    field :rotate_seconds, :integer
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime

    # Form fields: the ids of the views, in order, and the expiry as a
    # number of days from now (creation only).
    field :view_ids, {:array, :integer}, virtual: true, default: []
    field :expires_in_days, :integer, virtual: true

    belongs_to :user, User

    has_many :token_views, DisplayTokenView,
      preload_order: [asc: :position, asc: :id],
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "The most views a token can have."
  @spec max_views() :: pos_integer()
  def max_views, do: @max_views

  @doc "The allowed seconds between views."
  @spec rotate_range() :: Range.t()
  def rotate_range, do: @rotate_range

  @doc "The expiries a token can be created with, in days (or none)."
  @spec expiry_days() :: [pos_integer()]
  def expiry_days, do: @expiry_days

  @doc """
  Changes the name, views and rotation. `visible_ids` are the ids of the
  views the user making the change sees: views the token doesn't have yet
  must be among them (`view_ids` holds the current ones, see
  `Sentinelix.DisplayTokens.change_token/3`). The views are kept in the
  order given.
  """
  @spec changeset(t(), map(), [integer()]) :: Ecto.Changeset.t()
  def changeset(token, attrs, visible_ids) do
    token
    |> cast(normalize_view_ids(attrs), [:name, :rotate_seconds, :view_ids])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, max: @max_name_length)
    |> validate_number(:rotate_seconds,
      greater_than_or_equal_to: @rotate_range.first,
      less_than_or_equal_to: @rotate_range.last
    )
    |> update_change(:view_ids, &Enum.uniq/1)
    |> validate_views(visible_ids)
    |> put_token_views()
  end

  @doc """
  The changeset of a new token: `changeset/3`, the expiry and the token's
  hash.
  """
  @spec create_changeset(t(), map(), [integer()], binary()) :: Ecto.Changeset.t()
  def create_changeset(token, attrs, visible_ids, token_hash) do
    token
    |> changeset(attrs, visible_ids)
    |> cast(attrs, [:expires_in_days])
    |> validate_inclusion(:expires_in_days, @expiry_days)
    |> put_expiry()
    |> put_change(:token_hash, token_hash)
    |> unique_constraint(:token_hash)
  end

  # Checkboxes send "" for none (a hidden input) and ids as strings.
  defp normalize_view_ids(%{} = attrs) do
    Enum.into(attrs, %{}, fn
      {key, ids} when key in ["view_ids", :view_ids] and is_list(ids) ->
        {key, Enum.reject(ids, &(&1 in ["", nil]))}

      pair ->
        pair
    end)
  end

  defp validate_views(changeset, visible_ids) do
    ids = get_field(changeset, :view_ids)

    cond do
      ids == [] ->
        add_error(changeset, :view_ids, "pick at least one view")

      length(ids) > @max_views ->
        add_error(changeset, :view_ids, "pick at most #{@max_views} views")

      (ids -- changeset.data.view_ids) -- visible_ids != [] ->
        add_error(changeset, :view_ids, "you can only choose views you can see")

      true ->
        changeset
    end
  end

  defp put_token_views(%Ecto.Changeset{valid?: true} = changeset) do
    case fetch_change(changeset, :view_ids) do
      {:ok, ids} ->
        views =
          ids
          |> Enum.with_index()
          |> Enum.map(fn {id, position} ->
            %DisplayTokenView{saved_view_id: id, position: position}
          end)

        put_assoc(changeset, :token_views, views)

      :error ->
        changeset
    end
  end

  defp put_token_views(changeset), do: changeset

  defp put_expiry(changeset) do
    case get_change(changeset, :expires_in_days) do
      nil ->
        changeset

      days ->
        expires_at = DateTime.utc_now(:second) |> DateTime.add(days, :day)
        put_change(changeset, :expires_at, expires_at)
    end
  end
end
