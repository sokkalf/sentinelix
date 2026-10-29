defmodule Sentinelix.Accounts.User do
  @moduledoc """
  A user of Sentinelix.

  There are two kinds of users:

    * **OIDC users** are provisioned just-in-time on their first login through
      the OpenID Connect provider and are identified by `oidc_issuer` +
      `oidc_subject`. Their `email` and `name` are refreshed from the claims
      on every login.
    * **Local users** have a password (`hashed_password`) and are only used as
      a break-glass fallback when the IdP is unavailable or not configured.
      They are created with `mix sentinelix.create_admin` or the
      `ADMIN_EMAIL`/`ADMIN_PASSWORD` environment variables.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :name, :string
    field :oidc_issuer, :string
    field :oidc_subject, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :last_login_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for users provisioned from OpenID Connect claims.
  """
  def oidc_changeset(user, attrs) do
    user
    |> cast(attrs, [:oidc_issuer, :oidc_subject, :email, :name, :last_login_at])
    |> validate_required([:oidc_issuer, :oidc_subject])
    |> validate_length(:email, max: 255)
    |> validate_length(:name, max: 255)
    |> unique_constraint([:oidc_issuer, :oidc_subject])
  end

  @doc """
  Changeset for local (break-glass) users.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database. Defaults to `true`. Set it to `false` when only
      validating the form.
  """
  def local_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :name])
    |> validate_email()
    |> password_changeset(attrs, opts)
  end

  @doc """
  Changeset for setting the password of a local user.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    |> maybe_hash_password(opts)
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email, name: :users_local_email_index)
  end

  defp maybe_hash_password(changeset, opts) do
    password = get_change(changeset, :password)

    if Keyword.get(opts, :hash_password, true) && password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Verifies the password of a local user.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%__MODULE__{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and is_binary(password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  @doc """
  Returns true for local (password) users.
  """
  def local?(%__MODULE__{hashed_password: hashed_password}), do: is_binary(hashed_password)

  @doc """
  A human friendly name for the user.
  """
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{email: email}) when is_binary(email) and email != "", do: email
  def display_name(%__MODULE__{oidc_subject: sub}) when is_binary(sub), do: sub
  def display_name(%__MODULE__{}), do: "user"
end
