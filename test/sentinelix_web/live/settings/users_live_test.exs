defmodule SentinelixWeb.Settings.UsersLiveTest do
  use SentinelixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sentinelix.AccountsFixtures

  alias Sentinelix.Accounts

  test "requires login", %{conn: conn} do
    assert conn |> get(~p"/settings/users") |> redirected_to() == ~p"/login"
  end

  describe "logged in" do
    setup :register_and_log_in_user

    test "lists users with type, sessions and the current user", %{conn: conn, user: user} do
      oidc = oidc_user_fixture(%{name: "Olivia"})

      {:ok, view, _html} = live(conn, ~p"/settings/users")

      me = view |> element("#user-#{user.id}") |> render()
      assert me =~ "You"
      assert me =~ "Local"
      refute has_element?(view, "#delete-#{user.id}")
      refute has_element?(view, "#revoke-#{user.id}")

      row = view |> element("#user-#{oidc.id}") |> render()
      assert row =~ "Olivia"
      assert row =~ "OIDC"
      assert has_element?(view, "#revoke-#{oidc.id}[disabled]")
    end

    test "revokes the sessions of a user and disconnects them", %{conn: conn} do
      other = user_fixture()
      token = Accounts.generate_user_session_token(other)
      SentinelixWeb.Endpoint.subscribe("users_sessions:#{Base.url_encode64(token)}")

      {:ok, view, _html} = live(conn, ~p"/settings/users")
      assert view |> element("#user-#{other.id} td.tabular-nums") |> render() =~ "1"

      assert view |> element("#revoke-#{other.id}") |> render_click() =~ "Revoked all sessions"
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute Accounts.get_user_by_session_token(token)
      assert has_element?(view, "#revoke-#{other.id}[disabled]")
    end

    test "deletes a user", %{conn: conn} do
      other = user_fixture()
      token = Accounts.generate_user_session_token(other)
      SentinelixWeb.Endpoint.subscribe("users_sessions:#{Base.url_encode64(token)}")

      {:ok, view, _html} = live(conn, ~p"/settings/users")
      assert view |> element("#delete-#{other.id}") |> render_click() =~ "Deleted"
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute has_element?(view, "#user-#{other.id}")
      refute Accounts.get_user(other.id)
    end

    test "refuses to act on the own account", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings/users")
      assert render_click(view, "delete", %{"id" => user.id}) =~ "your own account"
      assert render_click(view, "revoke", %{"id" => user.id}) =~ "your own account"
      assert Accounts.get_user(user.id)
    end
  end
end
