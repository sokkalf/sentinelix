defmodule Sentinelix.DisplayTokensFixtures do
  @moduledoc """
  Test helpers for creating display tokens via `Sentinelix.DisplayTokens`.
  """

  alias Sentinelix.Accounts.{Scope, User}
  alias Sentinelix.DisplayTokens

  @doc """
  Creates a display token of `owner` (a user or scope) for `views` (saved
  views the owner sees). Returns `{token, display_token}`, `token` being
  the secret for `/wall/<token>`.
  """
  def display_token_fixture(owner, views, attrs \\ %{}) do
    scope =
      case owner do
        %Scope{} = scope -> scope
        %User{} = user -> Scope.for_user(user)
      end

    attrs = Enum.into(attrs, %{view_ids: Enum.map(views, & &1.id)})
    {:ok, token, display_token} = DisplayTokens.create_token(scope, attrs)
    {token, display_token}
  end
end
