defmodule SentinelixWeb.SessionControllerTest do
  use SentinelixWeb.ConnCase, async: false

  import Sentinelix.AccountsFixtures
  import Sentinelix.Test.AuthHelpers

  alias Sentinelix.Accounts

  describe "GET /login without OIDC" do
    test "shows the local login form", %{conn: conn} do
      user_fixture()
      html = conn |> get(~p"/login") |> html_response(200)

      assert html =~ "local-login-form"
      refute html =~ "Sign in with"
      refute html =~ "admin-hint"
    end

    test "hints at creating an admin when no local user exists", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)

      assert html =~ "admin-hint"
      assert html =~ "mix sentinelix.create_admin"
    end

    test "explains when no login method is enabled", %{conn: conn} do
      put_app_env(:local_auth_enabled, false)
      html = conn |> get(~p"/login") |> html_response(200)

      refute html =~ "local-login-form"
      assert html =~ "No login method is enabled"
    end

    test "redirects logged in users", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/login")
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /login" do
    setup do
      %{user: user_fixture()}
    end

    test "logs the user in", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => String.upcase(user.email), "password" => valid_user_password()}
        })

      assert token = get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_session_token(token).id == user.id
      assert Accounts.get_user!(user.id).last_login_at

      conn = get(conn, ~p"/")
      html = html_response(conn, 200)
      assert html =~ user.email
      assert html =~ "Log out"
    end

    test "renews the session", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(%{"leftover" => "value"})
        |> post(~p"/login", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      refute get_session(conn, "leftover")
      assert get_session(conn, :live_socket_id)
    end

    test "rejects a wrong password", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/login", %{"user" => %{"email" => user.email, "password" => "wrong"}})

      html = html_response(conn, 401)
      assert html =~ "Invalid email or password"
      assert html =~ user.email
      refute get_session(conn, :user_token)
    end

    test "rate limits attempts per client IP", %{conn: conn, user: user} do
      {limit, _period} = Application.fetch_env!(:sentinelix, Sentinelix.RateLimit)[:login]
      await_rate_limit_window(:login)
      wrong = %{"user" => %{"email" => user.email, "password" => "wrong"}}

      for _ <- 1..limit do
        assert build_conn()
               |> Map.put(:remote_ip, conn.remote_ip)
               |> post(~p"/login", wrong)
               |> html_response(401)
      end

      # Even the right password is refused now.
      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert html_response(conn, 429) =~ "Too many login attempts"
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..60
      refute get_session(conn, :user_token)

      # Other clients are not affected.
      conn =
        post(build_conn() |> Map.put(:remote_ip, unique_ip()), ~p"/login", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/"
    end

    test "rejects unknown users", %{conn: conn} do
      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => "nobody@example.com", "password" => valid_user_password()}
        })

      assert html_response(conn, 401) =~ "Invalid email or password"
    end

    test "rejects OIDC users (they have no password)", %{conn: conn} do
      oidc_user = oidc_user_fixture()

      conn =
        post(conn, ~p"/login", %{"user" => %{"email" => oidc_user.email, "password" => ""}})

      assert html_response(conn, 401) =~ "Invalid email or password"
    end

    test "rejects malformed params", %{conn: conn} do
      conn = post(conn, ~p"/login", %{})
      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
    end

    test "is refused when local auth is disabled", %{conn: conn, user: user} do
      put_app_env(:local_auth_enabled, false)

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "disabled"
      refute get_session(conn, :user_token)
    end
  end

  describe "DELETE /logout" do
    setup :register_and_log_in_user

    test "logs the user out and revokes the session", %{conn: conn} do
      token = get_session(conn, :user_token)
      conn = delete(conn, ~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_token)
      refute Accounts.get_user_by_session_token(token)

      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/login"
    end

    test "disconnects the session's LiveViews", %{conn: conn} do
      conn = get(conn, ~p"/")
      live_socket_id = get_session(conn, :live_socket_id)
      SentinelixWeb.Endpoint.subscribe(live_socket_id)

      delete(conn, ~p"/logout")

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "works when not logged in" do
      conn = delete(build_conn(), ~p"/logout")
      assert redirected_to(conn) == ~p"/login"
    end
  end
end
