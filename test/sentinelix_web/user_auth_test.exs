defmodule SentinelixWeb.UserAuthTest do
  use SentinelixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sentinelix.AccountsFixtures

  alias Phoenix.LiveView
  alias Sentinelix.Accounts
  alias Sentinelix.Accounts.Scope
  alias SentinelixWeb.UserAuth

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, SentinelixWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{user: user_fixture(), conn: conn}
  end

  describe "log_in_user/3" do
    test "stores a session token and redirects", %{conn: conn, user: user} do
      conn = UserAuth.log_in_user(conn, user)

      assert token = get_session(conn, :user_token)
      assert get_session(conn, :live_socket_id) == "users_sessions:#{Base.url_encode64(token)}"
      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_session_token(token).id == user.id
    end

    test "redirects to the stored return path", %{conn: conn, user: user} do
      conn = conn |> put_session(:user_return_to, "/monitor/x") |> UserAuth.log_in_user(user)
      assert redirected_to(conn) == "/monitor/x"
    end

    test "keeps the OIDC ID token for logout", %{conn: conn, user: user} do
      conn = UserAuth.log_in_user(conn, user, oidc_id_token: "raw.id.token")
      token = get_session(conn, :user_token)

      assert %{oidc_id_token: "raw.id.token"} = Accounts.delete_user_session_token(token)
    end
  end

  describe "fetch_current_scope_for_user/2" do
    test "assigns the user from the session", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)

      conn =
        conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert conn.assigns.current_scope.groups == []
    end

    test "puts the user's OIDC groups in the scope", %{conn: conn} do
      user = oidc_user_fixture(%{groups: ["ops"]})
      token = Accounts.generate_user_session_token(user)

      conn =
        conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.groups == ["ops"]
    end

    test "assigns nil without a token", %{conn: conn} do
      conn = UserAuth.fetch_current_scope_for_user(conn, [])
      assert conn.assigns.current_scope == nil
    end

    test "assigns nil for revoked and expired tokens", %{conn: conn, user: user} do
      revoked = Accounts.generate_user_session_token(user)
      Accounts.delete_user_session_token(revoked)

      expired = Accounts.generate_user_session_token(user)
      offset_user_token(expired, -15, :day)

      for token <- [revoked, expired] do
        conn =
          conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

        assert conn.assigns.current_scope == nil
      end
    end
  end

  describe "require_authenticated_user/2" do
    test "redirects to the login page and stores the return path", %{conn: conn} do
      conn =
        %{conn | path_info: ["monitor", "x"], query_string: "a=1"}
        |> fetch_flash()
        |> assign(:current_scope, nil)
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/login"
      assert get_session(conn, :user_return_to) == "/monitor/x?a=1"
    end

    test "does not store the return path for non-GET requests", %{conn: conn} do
      conn =
        %{conn | method: "POST", path_info: ["foo"]}
        |> fetch_flash()
        |> assign(:current_scope, nil)
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      refute get_session(conn, :user_return_to)
    end

    test "passes through logged in users", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
    end
  end

  describe "on_mount :require_authenticated" do
    test "assigns the current scope", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      socket = %LiveView.Socket{endpoint: SentinelixWeb.Endpoint, assigns: %{__changed__: %{}}}

      assert {:cont, socket} =
               UserAuth.on_mount(:require_authenticated, %{}, %{"user_token" => token}, socket)

      assert socket.assigns.current_scope.user.id == user.id
    end

    test "halts without a valid session" do
      socket = %LiveView.Socket{
        endpoint: SentinelixWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, halted} =
               UserAuth.on_mount(:require_authenticated, %{}, %{"user_token" => "bad"}, socket)

      assert halted.assigns.current_scope == nil
      assert {:halt, _} = UserAuth.on_mount(:require_authenticated, %{}, %{}, socket)
    end
  end

  describe "on_mount :mount_current_scope" do
    test "assigns nil without a session" do
      socket = %LiveView.Socket{endpoint: SentinelixWeb.Endpoint, assigns: %{__changed__: %{}}}

      assert {:cont, socket} = UserAuth.on_mount(:mount_current_scope, %{}, %{}, socket)
      assert socket.assigns.current_scope == nil
    end
  end

  describe "app routes" do
    test "redirect anonymous requests to the login page", %{conn: conn} do
      for path <- [~p"/", ~p"/monitors/1", ~p"/admin/dashboard"] do
        conn = get(conn, path)
        assert redirected_to(conn) == ~p"/login"
      end
    end

    test "LiveViews redirect when the session is not valid", %{conn: conn, user: user} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")

      token = Accounts.generate_user_session_token(user)
      conn = put_session(conn, :user_token, token)
      assert {:ok, _view, _html} = live(conn, ~p"/")

      # revoked sessions can no longer mount
      Accounts.delete_all_user_session_tokens(user)
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
    end

    test "the LiveDashboard is available to logged in users", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> get(~p"/admin/dashboard")
      assert redirected_to(conn) =~ "/admin/dashboard/"
    end
  end
end
