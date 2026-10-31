defmodule Sentinelix.DisplayTokens.DisplayTokenView do
  @moduledoc """
  A saved view of a display token (see
  `Sentinelix.DisplayTokens.DisplayToken`), at its `position` in the
  rotation. Deleting the view deletes the row, so the token stops showing
  it.
  """

  use Ecto.Schema

  alias Sentinelix.DisplayTokens.DisplayToken
  alias Sentinelix.SavedViews.SavedView

  schema "display_token_views" do
    field :position, :integer, default: 0

    belongs_to :display_token, DisplayToken
    belongs_to :saved_view, SavedView
  end

  @type t :: %__MODULE__{}
end
