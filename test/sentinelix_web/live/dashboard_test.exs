defmodule SentinelixWeb.Live.DashboardTest do
  use SentinelixWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET / renders the dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Sentinelix"

    {:ok, _view, html} = live(conn)
    assert html =~ "Sentinelix"
  end
end
