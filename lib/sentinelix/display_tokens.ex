defmodule Sentinelix.DisplayTokens do
  @moduledoc """
  Display tokens: read-only access to some saved views for a wall or kiosk
  display (`/wall/<token>`, see `SentinelixWeb.WallLive`), so the screen
  needs no logged in account. See `Sentinelix.DisplayTokens.DisplayToken`.

  ## Tokens

  A token is 32 random bytes, URL-safe Base64 encoded. Only its SHA-256 is
  stored: `create_token/2` returns the token once, and a lost token can't
  be shown again, only revoked (`delete_token/2`) and replaced. Tokens are
  looked up by their hash (`verify_token/1`); unknown, malformed and
  expired tokens are all just `:error`, so they can't be told apart.

  ## What a token shows

  A logged in user creates tokens for views they see, and manages only
  their own tokens. The display shows the token's views that its creator
  sees **at the time** (`display_views/1`): a view that is made personal
  by its owner, or scoped to groups the creator is no longer in, stops
  being shown, and shows again if the creator sees it again. Deleting a
  view removes it from all tokens; deleting the creator deletes their
  tokens.

  ## PubSub events

  Changing a token broadcasts `{:display_token_changed}`, deleting it
  `{:display_token_revoked}` on the token's topic (`subscribe/1`), so open
  displays update or disconnect right away. Displays also check their
  token again from time to time (`get_valid_token/1`), which covers
  expiry and changes without an event (the creator's groups at their next
  login).
  """

  import Ecto.Query, warn: false

  alias Phoenix.PubSub
  alias Sentinelix.Accounts.{Scope, User}
  alias Sentinelix.DisplayTokens.{DisplayToken, DisplayTokenView}
  alias Sentinelix.Repo
  alias Sentinelix.SavedViews
  alias Sentinelix.SavedViews.SavedView

  @pubsub Sentinelix.PubSub
  @rand_size 32
  @touch_interval_s 60

  ## PubSub

  @doc """
  Subscribes the caller to the events of a token (`{:display_token_changed}`,
  `{:display_token_revoked}`).
  """
  @spec subscribe(DisplayToken.t() | integer()) :: :ok | {:error, term()}
  def subscribe(token), do: PubSub.subscribe(@pubsub, topic(token))

  defp topic(%DisplayToken{id: id}), do: topic(id)
  defp topic(id) when is_integer(id), do: "display_token:#{id}"

  defp broadcast(token, event), do: PubSub.broadcast(@pubsub, topic(token), event)

  ## Managing tokens

  @doc """
  The tokens of the scope's user, newest first, with their views (in
  order) preloaded as `token_views` with their `saved_view`.
  """
  @spec list_tokens(Scope.t()) :: [DisplayToken.t()]
  def list_tokens(%Scope{user: %User{id: user_id}}) do
    from(t in DisplayToken, where: t.user_id == ^user_id, order_by: [desc: t.id])
    |> Repo.all()
    |> preload_views()
  end

  @doc "Gets one of the scope's user's tokens by id (views preloaded), or nil."
  @spec get_token(Scope.t(), integer() | String.t()) :: DisplayToken.t() | nil
  def get_token(%Scope{user: %User{id: user_id}}, id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %DisplayToken{} = token <- Repo.get_by(DisplayToken, id: id, user_id: user_id) do
      preload_views(token)
    else
      _ -> nil
    end
  end

  defp preload_views(tokens) do
    tokens
    |> Repo.preload(token_views: :saved_view)
    |> put_view_ids()
  end

  defp put_view_ids(tokens) when is_list(tokens), do: Enum.map(tokens, &put_view_ids/1)

  defp put_view_ids(%DisplayToken{token_views: views} = token) when is_list(views),
    do: %{token | view_ids: Enum.map(views, & &1.saved_view_id)}

  @doc """
  A changeset of a token's name, views and rotation for forms (with the
  expiry for a new token).
  """
  @spec change_token(Scope.t(), DisplayToken.t(), map()) :: Ecto.Changeset.t()
  def change_token(%Scope{} = scope, %DisplayToken{} = token, attrs \\ %{}) do
    if token.id,
      do: DisplayToken.changeset(token, attrs, visible_view_ids(scope)),
      else: DisplayToken.create_changeset(token, attrs, visible_view_ids(scope), <<>>)
  end

  @doc """
  Creates a token for the scope's user with the name, views (`view_ids`,
  in order), rotation and expiry (`expires_in_days`) in `attrs`. The
  views must be ones the user sees.

  Returns `{:ok, token, display_token}`: `token` is the secret, shown to
  the user once and never stored.
  """
  @spec create_token(Scope.t(), map()) ::
          {:ok, String.t(), DisplayToken.t()} | {:error, Ecto.Changeset.t()}
  def create_token(%Scope{user: %User{id: user_id}} = scope, attrs) do
    token = :crypto.strong_rand_bytes(@rand_size) |> Base.url_encode64(padding: false)

    %DisplayToken{user_id: user_id}
    |> DisplayToken.create_changeset(attrs, visible_view_ids(scope), hash(token))
    |> Repo.insert()
    |> case do
      {:ok, display_token} -> {:ok, token, preload_views(display_token)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Changes the name, views and rotation of one of the scope's user's
  tokens; new views must be ones the user sees. Open displays update.
  """
  @spec update_token(Scope.t(), DisplayToken.t(), map()) ::
          {:ok, DisplayToken.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def update_token(%Scope{} = scope, %DisplayToken{} = token, attrs) do
    with :ok <- authorize(scope, token),
         {:ok, token} <-
           token
           |> preload_views()
           |> DisplayToken.changeset(attrs, visible_view_ids(scope))
           |> Repo.update(stale_error_field: :id) do
      broadcast(token, {:display_token_changed})
      {:ok, preload_views(token)}
    end
  end

  @doc """
  Revokes (deletes) one of the scope's user's tokens. Open displays
  disconnect.
  """
  @spec delete_token(Scope.t(), DisplayToken.t()) ::
          {:ok, DisplayToken.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def delete_token(%Scope{} = scope, %DisplayToken{} = token) do
    with :ok <- authorize(scope, token),
         {:ok, token} <- Repo.delete(token, stale_error_field: :id) do
      broadcast(token, {:display_token_revoked})
      {:ok, token}
    end
  end

  @doc """
  Deletes all tokens of a user (who is being deleted), returning their
  ids for `broadcast_revoked/1` once the deletion is committed.
  """
  @spec delete_user_tokens(User.t()) :: [integer()]
  def delete_user_tokens(%User{id: user_id}) do
    {_count, ids} =
      Repo.delete_all(from t in DisplayToken, where: t.user_id == ^user_id, select: t.id)

    ids
  end

  @doc "Disconnects the open displays of deleted tokens."
  @spec broadcast_revoked([integer()]) :: :ok
  def broadcast_revoked(ids), do: Enum.each(ids, &broadcast(&1, {:display_token_revoked}))

  defp authorize(%Scope{user: %User{id: user_id}}, %DisplayToken{user_id: user_id}), do: :ok
  defp authorize(_scope, _token), do: {:error, :forbidden}

  defp visible_view_ids(scope), do: scope |> SavedViews.list_views() |> Enum.map(& &1.id)

  ## Displays

  @doc """
  Verifies a token from a display: returns the `DisplayToken` if it exists
  and hasn't expired, otherwise `:error` (whatever the reason). Marks the
  token as used.
  """
  @spec verify_token(term()) :: {:ok, DisplayToken.t()} | :error
  def verify_token(token) when is_binary(token) do
    if well_formed?(token),
      do: token |> hash() |> valid_query(:token_hash) |> fetch_valid(),
      else: :error
  end

  def verify_token(_token), do: :error

  @doc """
  Gets a token by id if it still exists and hasn't expired, for displays
  checking their token again. Marks the token as used.
  """
  @spec get_valid_token(integer()) :: {:ok, DisplayToken.t()} | :error
  def get_valid_token(id) when is_integer(id), do: id |> valid_query(:id) |> fetch_valid()

  defp valid_query(value, field) do
    now = DateTime.utc_now(:second)

    from t in DisplayToken,
      where: field(t, ^field) == ^value,
      where: is_nil(t.expires_at) or t.expires_at > ^now
  end

  defp fetch_valid(query) do
    case Repo.one(query) do
      %DisplayToken{} = token -> {:ok, touch(token)}
      nil -> :error
    end
  end

  # 32 bytes in URL-safe Base64 without padding are 43 characters.
  defp well_formed?(token), do: byte_size(token) == 43 and token =~ ~r/\A[A-Za-z0-9_-]+\z/

  defp hash(token), do: :crypto.hash(:sha256, token)

  # At most once a minute, so displays checking their token don't write
  # on every check.
  defp touch(%DisplayToken{} = token) do
    now = DateTime.utc_now(:second)
    stale = DateTime.add(now, -@touch_interval_s, :second)

    {count, _} =
      Repo.update_all(
        from(t in DisplayToken,
          where: t.id == ^token.id,
          where: is_nil(t.last_used_at) or t.last_used_at <= ^stale
        ),
        set: [last_used_at: now]
      )

    if count == 1, do: %{token | last_used_at: now}, else: token
  end

  @doc """
  The views a display of the token shows, in order: the token's views that
  its creator sees now (see the module docs). Empty when the creator is
  gone.
  """
  @spec display_views(DisplayToken.t()) :: [SavedView.t()]
  def display_views(%DisplayToken{} = token) do
    case Repo.get(User, token.user_id) do
      nil ->
        []

      user ->
        scope = Scope.for_user(user)

        from(tv in DisplayTokenView,
          join: v in assoc(tv, :saved_view),
          where: tv.display_token_id == ^token.id,
          order_by: [asc: tv.position, asc: tv.id],
          select: v
        )
        |> Repo.all()
        |> Enum.filter(&SavedViews.visible?(scope, &1))
    end
  end
end
