defmodule Sentinelix.Accounts.UserToken do
  @moduledoc """
  Server-side session tokens.

  Every login creates a row; the random token is stored in the (signed and
  encrypted) session cookie. Deleting the row revokes the session.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Sentinelix.Accounts.UserToken

  @rand_size 32

  # How long a session is valid. Keep in sync with the session cookie
  # `max_age` in `SentinelixWeb.Endpoint`.
  @session_validity_in_days 14

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :oidc_id_token, :string, redact: true
    field :authenticated_at, :utc_datetime
    belongs_to :user, Sentinelix.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def session_validity_in_days, do: @session_validity_in_days

  @doc """
  Builds a session token for the user.

  Returns `{raw_token, %UserToken{}}`; the struct still has to be inserted.

  ## Options

    * `:oidc_id_token` - the raw ID token of an OIDC login, used as
      `id_token_hint` for RP-initiated logout.
  """
  def build_session_token(user, opts \\ []) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {token,
     %UserToken{
       token: token,
       context: "session",
       user_id: user.id,
       oidc_id_token: Keyword.get(opts, :oidc_id_token),
       authenticated_at: DateTime.utc_now(:second)
     }}
  end

  @doc """
  Returns a query for the user of a valid (not expired) session token.
  """
  def verify_session_token_query(token) do
    from token in by_token_and_context_query(token, "session"),
      join: user in assoc(token, :user),
      where: token.inserted_at > ago(@session_validity_in_days, "day"),
      select: user
  end

  def by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end

  def by_user_query(user) do
    from t in UserToken, where: t.user_id == ^user.id
  end

  def expired_sessions_query do
    from t in UserToken,
      where: t.context == "session" and t.inserted_at <= ago(@session_validity_in_days, "day")
  end
end
