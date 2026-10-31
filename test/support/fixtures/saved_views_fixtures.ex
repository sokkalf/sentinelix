defmodule Sentinelix.SavedViewsFixtures do
  @moduledoc """
  Test helpers for creating saved views via `Sentinelix.SavedViews`.
  """

  alias Sentinelix.Accounts.{Scope, User}
  alias Sentinelix.Monitoring.View
  alias Sentinelix.SavedViews

  @doc """
  Saves a view for `owner` (a user or scope). `attrs` may hold `:params`
  (URL parameters of the view) besides the name, visibility and groups. A
  user's groups are taken from the attrs' groups, so any group can be used.
  """
  def saved_view_fixture(owner, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: "View #{System.unique_integer([:positive])}"})
    {:ok, view} = View.from_params(Map.get(attrs, :params, %{}))

    scope =
      case owner do
        %Scope{} = scope -> scope
        %User{} = user -> %{Scope.for_user(user) | groups: Map.get(attrs, :groups, [])}
      end

    {:ok, saved} = SavedViews.create_view(scope, view, Map.delete(attrs, :params))
    saved
  end
end
