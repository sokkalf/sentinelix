defmodule Sentinelix.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The scope carries information about the caller, such as which user
  initiated a call. It is assigned as `@current_scope` in conns and
  LiveViews by `SentinelixWeb.UserAuth`.

  `groups` are the user's OIDC groups as of their last login (none for
  local users), kept here so visibility checks (see
  `Sentinelix.SavedViews`) don't need the user loaded again.
  """

  alias Sentinelix.Accounts.User

  defstruct user: nil, groups: []

  @type t :: %__MODULE__{user: User.t() | nil, groups: [String.t()]}

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{} = user), do: %__MODULE__{user: user, groups: user.groups || []}
  def for_user(nil), do: nil
end
