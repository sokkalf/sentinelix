defmodule Sentinelix.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The scope carries information about the caller, such as which user
  initiated a call. It is assigned as `@current_scope` in conns and
  LiveViews by `SentinelixWeb.UserAuth`.
  """

  alias Sentinelix.Accounts.User

  defstruct user: nil

  @type t :: %__MODULE__{user: User.t() | nil}

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
