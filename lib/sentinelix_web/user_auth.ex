defmodule SentinelixWeb.UserAuth do
  @moduledoc """
  Session handling for controllers (plugs) and LiveViews (`on_mount` hooks).

  The session cookie only holds a random token; the matching row in
  `users_tokens` makes the session valid, so sessions can be revoked
  server-side (see `Sentinelix.Accounts.delete_all_user_session_tokens/1`
  and `disconnect_sessions/1`).

  ## Usage in the router

      pipe_through [:browser, :require_authenticated_user]

      live_session :require_authenticated_user,
        on_mount: [{SentinelixWeb.UserAuth, :require_authenticated}] do
        live "/things", ThingLive.Index
      end

  Every LiveView and controller in such a scope gets `@current_scope`
  (a `Sentinelix.Accounts.Scope`) with the logged in user.
  """

  use SentinelixWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Sentinelix.Accounts
  alias Sentinelix.Accounts.Scope
  alias Sentinelix.Auth.OIDC

  @doc """
  Logs the user in: creates a session token, renews the session (to avoid
  fixation attacks) and redirects to the page the user originally wanted.

  ## Options

    * `:oidc_id_token` - raw ID token, stored for RP-initiated logout.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = Accounts.generate_user_session_token(user, opts)
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out: revokes the session token, disconnects LiveViews of
  this session and, for OIDC sessions whose provider advertises an
  `end_session_endpoint`, redirects to the IdP's RP-initiated logout.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    deleted_token = user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      SentinelixWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn = renew_session(conn)

    case deleted_token && OIDC.logout_url(deleted_token.oidc_id_token, url(~p"/login")) do
      {:ok, logout_url} -> redirect(conn, external: logout_url)
      _ -> redirect(conn, to: ~p"/login")
    end
  end

  @doc """
  Disconnects all LiveViews belonging to the given (deleted) session tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      SentinelixWeb.Endpoint.broadcast(live_socket_id(token), "disconnect", %{})
    end)
  end

  @doc """
  Plug: assigns `:current_scope` from the session token (nil when logged out).
  """
  def fetch_current_scope_for_user(conn, _opts) do
    user =
      case get_session(conn, :user_token) do
        token when is_binary(token) -> Accounts.get_user_by_session_token(token)
        _ -> nil
      end

    assign(conn, :current_scope, Scope.for_user(user))
  end

  @doc """
  Plug: requires a logged in user, otherwise redirects to the login page.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc """
  Plug: redirects already logged in users away from the login pages.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  @doc """
  LiveView `on_mount` hooks.

    * `:mount_current_scope` - assigns `@current_scope` (may be nil).
    * `:require_authenticated` - assigns `@current_scope` and halts with a
      redirect to the login page when nobody is logged in. Use it for every
      app LiveView.

  ## Examples

      live_session :require_authenticated_user,
        on_mount: [{SentinelixWeb.UserAuth, :require_authenticated}] do
        live "/", Live.Dashboard
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/login")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      user =
        case session["user_token"] do
          token when is_binary(token) -> Accounts.get_user_by_session_token(token)
          _ -> nil
        end

      Scope.for_user(user)
    end)
  end

  @doc """
  Where users land after logging in.
  """
  def signed_in_path(_conn), do: ~p"/"

  # Renewing the session prevents fixation attacks; clearing it drops any
  # leftover data (e.g. a pending OIDC flow) from before the login.
  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, live_socket_id(token))
  end

  defp live_socket_id(token), do: "users_sessions:#{Base.url_encode64(token)}"

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
