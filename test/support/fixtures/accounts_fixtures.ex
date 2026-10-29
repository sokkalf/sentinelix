defmodule Sentinelix.AccountsFixtures do
  @moduledoc """
  Test helpers for creating users via the `Sentinelix.Accounts` context.
  """

  alias Sentinelix.Accounts

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def valid_user_password, do: "correct horse battery staple"

  @doc """
  Creates a local (password) user.
  """
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{email: unique_user_email(), password: valid_user_password()})
      |> Accounts.create_local_user()

    user
  end

  @doc """
  Creates an OIDC user.
  """
  def oidc_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        oidc_issuer: "https://idp.example.com",
        oidc_subject: "sub-#{System.unique_integer([:positive])}",
        email: unique_user_email(),
        name: "OIDC User"
      })
      |> Accounts.upsert_oidc_user()

    user
  end

  @doc """
  Moves a session token's `inserted_at` into the past.
  """
  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Sentinelix.Repo.update_all(
      Accounts.UserToken.by_token_and_context_query(token, "session"),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
