defmodule Sentinelix.Accounts do
  @moduledoc """
  The Accounts context: users and their sessions.

  See `Sentinelix.Accounts.User` for the difference between OIDC and local
  (break-glass) users. There is deliberately no self-registration.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Sentinelix.Accounts.{User, UserToken}
  alias Sentinelix.Repo

  ## Users

  @doc """
  Gets a single user. Raises `Ecto.NoResultsError` if the user does not exist.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a single user, or nil if the user does not exist.
  """
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Lists all users, ordered by name/email, each paired with the number of
  their active (not expired) sessions: `[{%User{}, session_count}]`.
  """
  @spec list_users_with_session_counts() :: [{User.t(), non_neg_integer()}]
  def list_users_with_session_counts do
    sessions =
      from t in UserToken,
        where:
          t.context == "session" and
            t.inserted_at > ago(^UserToken.session_validity_in_days(), "day"),
        group_by: t.user_id,
        select: %{user_id: t.user_id, count: count(t.id)}

    from(u in User,
      left_join: s in subquery(sessions),
      on: s.user_id == u.id,
      order_by: [asc: fragment("lower(coalesce(?, ?, ''))", u.name, u.email), asc: u.id],
      select: {u, coalesce(s.count, 0)}
    )
    |> Repo.all()
  end

  @doc """
  Deletes a user together with all of their sessions.

  Returns the deleted session tokens so connected LiveViews can be
  disconnected (see `SentinelixWeb.UserAuth.disconnect_sessions/1`).

  Note that an OIDC user who is still allowed to log in is provisioned
  again on their next login, and the bootstrap admin is recreated on boot
  while `ADMIN_EMAIL`/`ADMIN_PASSWORD` are set.
  """
  @spec delete_user(User.t()) :: {:ok, User.t(), [UserToken.t()]} | {:error, Ecto.Changeset.t()}
  def delete_user(%User{} = user) do
    Repo.transact(fn ->
      tokens = delete_all_user_session_tokens(user)

      with {:ok, user} <- Repo.delete(user) do
        {:ok, {user, tokens}}
      end
    end)
    |> case do
      {:ok, {user, tokens}} -> {:ok, user, tokens}
      error -> error
    end
  end

  @doc """
  Gets the user provisioned for an OIDC identity, or nil.
  """
  def get_user_by_oidc_identity(issuer, subject)
      when is_binary(issuer) and is_binary(subject) do
    Repo.get_by(User, oidc_issuer: issuer, oidc_subject: subject)
  end

  @doc """
  Creates or updates the user for an OIDC identity (just-in-time provisioning).

  Users are matched on `:oidc_issuer` + `:oidc_subject` only; `:email`,
  `:name` and `:groups` are overwritten with the latest values from the IdP
  (no `:groups` means none) and `last_login_at` is bumped.
  """
  def upsert_oidc_user(attrs) do
    attrs = Map.put(attrs, :last_login_at, DateTime.utc_now(:second))

    %User{}
    |> User.oidc_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:email, :name, :groups, :last_login_at, :updated_at]},
      conflict_target: [:oidc_issuer, :oidc_subject],
      returning: true
    )
  end

  @doc """
  Gets a local user by email and password. Returns nil if the email is
  unknown, the password is wrong or the user is not a local user.
  """
  def get_local_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_local_user_by_email(email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a local (password) user by email, case-insensitively.
  """
  def get_local_user_by_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    Repo.one(
      from u in User,
        where: fragment("lower(?)", u.email) == ^email and not is_nil(u.hashed_password)
    )
  end

  @doc """
  Returns true if at least one local user exists.
  """
  def local_users_exist? do
    Repo.exists?(from u in User, where: not is_nil(u.hashed_password))
  end

  @doc """
  Creates a local (break-glass) user.
  """
  def create_local_user(attrs) do
    %User{}
    |> User.local_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a local user, or resets the password if a local user with that
  email already exists. Used by `mix sentinelix.create_admin`.

  Returns `{:ok, :created | :updated, user}` or `{:error, changeset}`.
  """
  def create_or_reset_local_user(%{email: email, password: password} = attrs) do
    case get_local_user_by_email(email) do
      nil ->
        with {:ok, user} <- create_local_user(attrs), do: {:ok, :created, user}

      user ->
        with {:ok, user} <- reset_local_user_password(user, password),
             do: {:ok, :updated, user}
    end
  end

  @doc """
  Sets a new password for a local user and revokes all of the user's sessions.
  """
  def reset_local_user_password(%User{} = user, password) do
    changeset = User.password_changeset(user, %{password: password})

    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        Repo.delete_all(UserToken.by_user_query(user))
        {:ok, user}
      end
    end)
  end

  @doc """
  Creates the local admin from `ADMIN_EMAIL`/`ADMIN_PASSWORD` (the
  `:bootstrap_admin` config) unless a local user with that email exists.

  Existing users are never modified, so changing the env vars later does
  not reset a password; use `mix sentinelix.create_admin` for that.
  """
  def ensure_bootstrap_admin(config \\ Application.get_env(:sentinelix, :bootstrap_admin)) do
    with email when is_binary(email) and email != "" <- config[:email],
         password when is_binary(password) and password != "" <- config[:password] do
      case get_local_user_by_email(email) do
        nil -> create_bootstrap_admin(email, password)
        user -> {:ok, :exists, user}
      end
    else
      _ -> :skip
    end
  end

  defp create_bootstrap_admin(email, password) do
    case create_local_user(%{email: email, password: password}) do
      {:ok, user} ->
        Logger.info("Created local admin user #{user.email}")
        {:ok, :created, user}

      {:error, changeset} ->
        Logger.error(
          "Could not create local admin user from ADMIN_EMAIL/ADMIN_PASSWORD: " <>
            inspect(errors_on(changeset))
        )

        {:error, changeset}
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  ## Sessions

  @doc """
  Generates and stores a session token for the user.

  ## Options

    * `:oidc_id_token` - raw ID token, used later for RP-initiated logout.
  """
  def generate_user_session_token(%User{} = user, opts \\ []) do
    {token, user_token} = UserToken.build_session_token(user, opts)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user for a valid session token, or nil.
  """
  def get_user_by_session_token(token) when is_binary(token) do
    Repo.one(UserToken.verify_session_token_query(token))
  end

  @doc """
  Deletes the session token (logout / revocation).

  Returns the deleted `%UserToken{}` (so the caller can use its
  `oidc_id_token`), or nil if there was no such token.
  """
  def delete_user_session_token(token) when is_binary(token) do
    case Repo.delete_all(
           from(t in UserToken.by_token_and_context_query(token, "session"), select: t)
         ) do
      {1, [user_token]} -> user_token
      {0, []} -> nil
    end
  end

  @doc """
  Revokes all sessions of a user. Returns the deleted tokens so connected
  LiveViews can be disconnected (see `SentinelixWeb.UserAuth.disconnect_sessions/1`).
  """
  def delete_all_user_session_tokens(%User{} = user) do
    {_count, tokens} = Repo.delete_all(from(t in UserToken.by_user_query(user), select: t))
    tokens
  end

  @doc """
  Deletes expired session tokens.
  """
  def delete_expired_session_tokens do
    {count, _} = Repo.delete_all(UserToken.expired_sessions_query())
    count
  end

  @doc """
  Records a successful login of a user.
  """
  def touch_last_login(%User{} = user) do
    user
    |> Ecto.Changeset.change(last_login_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end
end
