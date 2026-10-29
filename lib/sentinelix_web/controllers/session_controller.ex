defmodule SentinelixWeb.SessionController do
  @moduledoc """
  Login page, local (break-glass) password login and logout.
  """
  use SentinelixWeb, :controller

  alias Sentinelix.{Accounts, Auth}
  alias SentinelixWeb.UserAuth

  def new(conn, _params) do
    render_login(conn, %{})
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    if Auth.local_auth_enabled?() do
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
