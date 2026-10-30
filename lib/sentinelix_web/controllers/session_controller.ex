defmodule SentinelixWeb.SessionController do
  @moduledoc """
  Login page, local (break-glass) password login and logout.

  Password login attempts are rate limited per client IP (`:login` bucket of
  `Sentinelix.RateLimit`, `LOGIN_RATE_LIMIT` in production).
  """
  use SentinelixWeb, :controller

  alias Sentinelix.{Accounts, Auth, RateLimit}
  alias SentinelixWeb.UserAuth

  def new(conn, _params) do
    render_login(conn, %{})
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    if Auth.local_auth_enabled?() do
      case RateLimit.check(:login, conn.remote_ip) do
        :ok ->
          log_in(conn, email, password)

        {:error, retry_after_ms} ->
          retry_after = div(retry_after_ms + 999, 1000)

          conn
          |> put_status(:too_many_requests)
          |> put_resp_header("retry-after", Integer.to_string(retry_after))
          |> put_flash(
            :error,
            "Too many login attempts. Try again in #{retry_after} seconds."
          )
          |> render_login(%{"email" => String.slice(email, 0, 160)})
      end
    else
      conn
      |> put_flash(:error, "Local login is disabled.")
      |> redirect(to: ~p"/login")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Invalid email or password.")
    |> redirect(to: ~p"/login")
  end

  defp log_in(conn, email, password) do
    case Accounts.get_local_user_by_email_and_password(email, password) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> put_flash(:error, "Invalid email or password.")
        |> render_login(%{"email" => String.slice(email, 0, 160)})

      user ->
        Accounts.touch_last_login(user)
        UserAuth.log_in_user(conn, user)
    end
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp render_login(conn, params) do
    oidc_enabled = Auth.oidc_enabled?()
    local_enabled = Auth.local_auth_enabled?()

    render(conn, :new,
      page_title: "Sign in",
      form: Phoenix.Component.to_form(params, as: "user"),
      oidc_enabled: oidc_enabled,
      provider_name: Auth.provider_name(),
      local_enabled: local_enabled,
      show_admin_hint: local_enabled and not Accounts.local_users_exist?()
    )
  end
end
