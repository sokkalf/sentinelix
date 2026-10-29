defmodule SentinelixWeb.Live.DashboardTest do
  use SentinelixWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET / redirects to the login page when logged out", %{conn: conn} do
    assert conn |> get(~p"/") |> redirected_to() == ~p"/login"
  end

  describe "logged in" do
    setup :register_and_log_in_user

    test "GET / renders the dashboard", %{conn: conn, user: user} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Sentinelix"

      {:ok, _view, html} = live(conn)
      assert html =~ "Sentinelix"
      assert html =~ user.email
    end
  end
end
