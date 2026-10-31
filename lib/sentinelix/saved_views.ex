defmodule Sentinelix.SavedViews do
  @moduledoc """
  Saved views: named `Sentinelix.Monitoring.View`s (a selector, grouping,
  sort and whatever else the dashboard URL holds), personal, shared or
  scoped to OIDC groups. See `Sentinelix.SavedViews.SavedView`.

  ## Visibility and permissions

  Every function that reads or changes views takes the caller's
  `Sentinelix.Accounts.Scope`. A user sees:

    * their own views (any visibility),
    * shared views (`:shared`) of all users,
    * group views (`:groups`) sharing at least one group with the scope's
      groups (the user's OIDC groups as of their last login).

  Views a user doesn't see are not found (`get_view/2` gives `nil`), so
  their existence doesn't leak. Only the owner changes, reorders or
  deletes a view; for anyone else these functions return
  `{:error, :forbidden}`. There is no admin
  role: if roles are added later, admins should be able to manage shared
  views too. A user can only scope a view to groups they are a member of.

  `get_view_for_display/1` loads a view by slug without a scope, for
  displays that are authorized another way (wall/kiosk mode, #44).

  ## Order

  `list_views/1` lists the user's own views first, in their order
  (`position`, see `move_view/3`), then the views others share with them,
  by name.

  ## Default view

  Each user can pick a view they see as their default (`set_default_view/2`),
  shown at `/`. It is stored on the user, cleared when the view is deleted
  and ignored while the user doesn't see it.

  ## PubSub events

  Every change of a view is broadcast as `{:saved_views_changed}` on the
  topic `subscribe/0` subscribes to. The event carries nothing, so
  subscribers reload what they are allowed to see.
  """

  import Ecto.Query, warn: false

  alias Phoenix.PubSub
  alias Sentinelix.Accounts.{Scope, User}
  alias Sentinelix.Monitoring.{Selector, View}
  alias Sentinelix.Repo
  alias Sentinelix.SavedViews.SavedView
  alias Sentinelix.StatusPages.StatusPage

  @pubsub Sentinelix.PubSub
  @topic "saved_views"
  @slug_attempts 5

  ## PubSub

  @doc "Subscribes the caller to `{:saved_views_changed}` events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSub.subscribe(@pubsub, @topic)

  defp broadcast_change(result) do
    with {:ok, _value} <- result do
      PubSub.broadcast(@pubsub, @topic, {:saved_views_changed})
    end

    result
  end

  ## Reading

  @doc """
  The views the scope's user sees, with their owners: their own in their
  order, then others' by name.
  """
  @spec list_views(Scope.t()) :: [SavedView.t()]
  def list_views(%Scope{user: %User{id: user_id}} = scope) do
    scope
    |> visible_query()
    |> preload(:owner)
    |> Repo.all()
    |> Enum.sort_by(fn view ->
      own = view.owner_id == user_id
      {not own, if(own, do: view.position, else: 0), String.downcase(view.name), view.id}
    end)
  end

  @doc "Gets a view the scope's user sees by its slug, with its owner, or nil."
  @spec get_view(Scope.t(), String.t()) :: SavedView.t() | nil
  def get_view(%Scope{} = scope, slug) when is_binary(slug) do
    scope
    |> visible_query()
    |> where([v], v.slug == ^slug)
    |> preload(:owner)
    |> Repo.one()
  end

  @doc """
  Gets a view by its slug **without checking who may see it**, or nil. For
  displays authorized by other means, such as a wall/kiosk display token;
  everything a user does goes through `get_view/2`.
  """
  @spec get_view_for_display(String.t()) :: SavedView.t() | nil
  def get_view_for_display(slug) when is_binary(slug), do: Repo.get_by(SavedView, slug: slug)

  @doc """
  The default view of the scope's user, or nil when they have none or no
  longer see it.
  """
  @spec default_view(Scope.t()) :: SavedView.t() | nil
  def default_view(%Scope{user: %User{default_view_id: nil}}), do: nil

  def default_view(%Scope{user: %User{default_view_id: id}} = scope) do
    scope
    |> visible_query()
    |> where([v], v.id == ^id)
    |> preload(:owner)
    |> Repo.one()
  end

  @doc "Whether the scope's user sees the view."
  @spec visible?(Scope.t(), SavedView.t()) :: boolean()
  def visible?(%Scope{user: %User{id: user_id}} = scope, %SavedView{} = view) do
    case view.visibility do
      _visibility when view.owner_id == user_id -> true
      :shared -> true
      :groups -> Enum.any?(view.groups, &(&1 in scope.groups))
      :personal -> false
    end
  end

  @doc "Whether the scope's user owns the view (and so may change it)."
  @spec owner?(Scope.t() | nil, SavedView.t()) :: boolean()
  def owner?(%Scope{user: %User{id: user_id}}, %SavedView{owner_id: user_id}), do: true
  def owner?(_scope, _view), do: false

  @doc """
  The view a saved view stores, as `Sentinelix.Monitoring.View.from_params/1`
  reads it: a stored selector that no longer parses gives
  `{:error, view, text, error}`.
  """
  @spec to_view(SavedView.t()) ::
          {:ok, View.t()} | {:error, View.t(), String.t(), Selector.Error.t()}
  def to_view(%SavedView{params: params}), do: View.from_params(params)

  @doc "Whether a saved view stores the given view."
  @spec same_view?(SavedView.t(), View.t()) :: boolean()
  def same_view?(%SavedView{params: params}, %View{} = view),
    do: params == stored_params(view)

  defp stored_params(view), do: Map.new(View.to_params(view), fn {k, v} -> {to_string(k), v} end)

  defp visible_query(%Scope{user: %User{id: user_id}, groups: groups}) do
    from v in SavedView,
      where:
        v.owner_id == ^user_id or v.visibility == :shared or
          (v.visibility == :groups and
             fragment("? && ?", v.groups, type(^groups, {:array, :string})))
  end

  ## Changing

  @doc """
  A changeset for the name, visibility and groups of a view, for forms.
  """
  @spec change_view(Scope.t(), SavedView.t(), map()) :: Ecto.Changeset.t()
  def change_view(%Scope{} = scope, %SavedView{} = view, attrs \\ %{}),
    do: SavedView.changeset(view, attrs, scope.groups)

  @doc """
  Saves a view for the scope's user, with the name, visibility and groups
  in `attrs`. The slug is derived from the name, with a number added when
  it's taken. The view goes after the user's other views.
  """
  @spec create_view(Scope.t(), View.t(), map()) ::
          {:ok, SavedView.t()} | {:error, Ecto.Changeset.t()}
  def create_view(%Scope{user: %User{id: user_id}} = scope, %View{} = view, attrs) do
    position =
      Repo.one(from v in SavedView, where: v.owner_id == ^user_id, select: max(v.position))

    changeset =
      %SavedView{owner_id: user_id, position: (position || -1) + 1}
      |> SavedView.changeset(attrs, scope.groups)
      |> SavedView.params_changeset(View.to_params(view))

    changeset
    |> insert_with_slug(@slug_attempts)
    |> broadcast_change()
  end

  # Tries the first free slug; another view taking it in the meantime gives
  # a unique constraint error, then the next one is tried.
  defp insert_with_slug(%Ecto.Changeset{valid?: false} = changeset, _attempts),
    do: {:error, changeset}

  defp insert_with_slug(changeset, attempts) do
    slug = free_slug(Ecto.Changeset.get_field(changeset, :name))

    case Repo.insert(SavedView.slug_changeset(changeset, slug)) do
      {:error, %{errors: [slug: _error]}} when attempts > 1 ->
        insert_with_slug(changeset, attempts - 1)

      result ->
        result
    end
  end

  defp free_slug(name) do
    base =
      case StatusPage.slugify(name) do
        "" -> "view"
        slug -> String.slice(slug, 0, 56) |> String.trim_trailing("-")
      end

    taken =
      Repo.all(
        from v in SavedView,
          where: v.slug == ^base or like(v.slug, ^"#{base}-%"),
          select: v.slug
      )
      |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  @doc """
  Changes the name, visibility and groups of a view. Owner only; the slug
  stays.
  """
  @spec update_view(Scope.t(), SavedView.t(), map()) ::
          {:ok, SavedView.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def update_view(%Scope{} = scope, %SavedView{} = view, attrs) do
    with :ok <- authorize_owner(scope, view) do
      view
      |> SavedView.changeset(attrs, scope.groups)
      |> Repo.update()
      |> broadcast_change()
    end
  end

  @doc "Stores another view in a saved view (\"Update view\"). Owner only."
  @spec update_view_params(Scope.t(), SavedView.t(), View.t()) ::
          {:ok, SavedView.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def update_view_params(%Scope{} = scope, %SavedView{} = saved, %View{} = view) do
    with :ok <- authorize_owner(scope, saved) do
      saved
      |> SavedView.params_changeset(View.to_params(view))
      |> Repo.update()
      |> broadcast_change()
    end
  end

  @doc "Deletes a view. Owner only."
  @spec delete_view(Scope.t(), SavedView.t()) ::
          {:ok, SavedView.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def delete_view(%Scope{} = scope, %SavedView{} = view) do
    with :ok <- authorize_owner(scope, view) do
      view |> Repo.delete() |> broadcast_change()
    end
  end

  @doc """
  Moves one of the user's views up or down in their order. Owner only;
  moving the first view up or the last down changes nothing.
  """
  @spec move_view(Scope.t(), SavedView.t(), :up | :down) ::
          {:ok, [SavedView.t()]} | {:error, :forbidden}
  def move_view(%Scope{user: %User{id: user_id}} = scope, %SavedView{} = view, direction)
      when direction in [:up, :down] do
    with :ok <- authorize_owner(scope, view) do
      Repo.transact(fn ->
        views =
          Repo.all(
            from v in SavedView,
              where: v.owner_id == ^user_id,
              order_by: [asc: v.position, asc: v.id],
              lock: "FOR UPDATE"
          )

        views = views |> swap(Enum.find_index(views, &(&1.id == view.id)), direction)

        {:ok,
         views
         |> Enum.with_index()
         |> Enum.map(fn {view, position} ->
           if view.position == position,
             do: view,
             else: view |> Ecto.Changeset.change(position: position) |> Repo.update!()
         end)}
      end)
      |> broadcast_change()
    end
  end

  defp swap(views, nil, _direction), do: views
  defp swap(views, 0, :up), do: views
  defp swap(views, index, :up), do: swap(views, index - 1, :down)

  defp swap(views, index, :down) when index + 1 < length(views) do
    views
    |> List.replace_at(index, Enum.at(views, index + 1))
    |> List.replace_at(index + 1, Enum.at(views, index))
  end

  defp swap(views, _index, :down), do: views

  @doc """
  Makes a view the default of the scope's user (shown at `/`), or clears it
  with nil. The user must see the view. Returns the updated user.
  """
  @spec set_default_view(Scope.t(), SavedView.t() | nil) ::
          {:ok, User.t()} | {:error, :not_found}
  def set_default_view(%Scope{user: user} = scope, view) do
    if is_nil(view) or visible?(scope, view) do
      {:ok, user |> Ecto.Changeset.change(default_view_id: view && view.id) |> Repo.update!()}
    else
      {:error, :not_found}
    end
  end

  defp authorize_owner(scope, view) do
    if owner?(scope, view), do: :ok, else: {:error, :forbidden}
  end
end
