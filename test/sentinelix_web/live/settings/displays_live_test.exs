defmodule SentinelixWeb.Settings.DisplaysLiveTest do
  use SentinelixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sentinelix.AccountsFixtures
  import Sentinelix.DisplayTokensFixtures
  import Sentinelix.SavedViewsFixtures

  alias Sentinelix.Accounts.Scope
  alias Sentinelix.{DisplayTokens, SavedViews}
  alias Sentinelix.DisplayTokens.DisplayToken
  alias Sentinelix.Repo

  test "requires a login", %{conn: conn} do
    assert conn |> get(~p"/settings/displays") |> redirected_to() == ~p"/login"
  end

  describe "logged in" do
    setup :register_and_log_in_user

    test "is in the settings navigation and linked from the views", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/displays")
      assert has_element?(view, "#app-nav a[aria-current='page']", "Wall displays")
      assert has_element?(view, "#no-displays")

      {:ok, view, _html} = live(conn, ~p"/views")
      assert has_element?(view, "#wall-displays[href='/settings/displays']")
    end

    test "creates a display and shows its URL once", %{conn: conn, scope: scope} do
      first = saved_view_fixture(scope, name: "First")
      second = saved_view_fixture(scope, name: "Second")

      {:ok, view, _html} = live(conn, ~p"/settings/displays")
      view |> element("#new-display") |> render_click()
      assert_patch(view, ~p"/settings/displays/new")

      assert view
             |> form("#display-form", display_token: %{view_ids: [""]})
             |> render_submit() =~ "pick at least one view"

      view
      |> form("#display-form",
        display_token: %{
          name: "Office TV",
          view_ids: ["", to_string(first.id), to_string(second.id)],
          rotate_seconds: "20",
          expires_in_days: "30"
        }
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/displays")

      url =
        view
        |> element("#created-display-url")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("value")
        |> hd()

      assert "/wall/" <> token = URI.parse(url).path
      assert {:ok, display_token} = DisplayTokens.verify_token(token)
      assert display_token.name == "Office TV"
      assert display_token.rotate_seconds == 20
      assert display_token.expires_at

      row = view |> element("#display-#{display_token.id}") |> render()
      assert row =~ "Office TV"
      assert row =~ "First"
      assert row =~ "Second"
      assert row =~ "every 20s"
      refute row =~ token

      # Shown once: gone when dismissed or on the next visit.
      view |> element("#dismiss-created") |> render_click()
      refute render(view) =~ token
      {:ok, _view, html} = live(conn, ~p"/settings/displays")
      refute html =~ token
    end

    test "only offers views the user sees", %{conn: conn} do
      other = user_fixture()
      shared = saved_view_fixture(other, name: "Theirs shared", visibility: :shared)
      _personal = saved_view_fixture(other, name: "Theirs personal")

      {:ok, view, html} = live(conn, ~p"/settings/displays/new")
      assert has_element?(view, "#display-view-#{shared.slug}")
      refute html =~ "Theirs personal"
    end

    test "says so without views", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/displays/new")
      assert has_element?(view, "#no-views")
      refute has_element?(view, "#display-form")
    end

    test "edits and revokes displays", %{conn: conn, scope: scope} do
      first = saved_view_fixture(scope, name: "First")
      second = saved_view_fixture(scope, name: "Second")
      {token, display_token} = display_token_fixture(scope, [first], name: "Lobby")

      {:ok, view, _html} = live(conn, ~p"/settings/displays")
      view |> element("#edit-display-#{display_token.id}") |> render_click()
      assert_patch(view, ~p"/settings/displays/#{display_token.id}/edit")
      assert has_element?(view, "#display-view-#{first.slug}[checked]")
      refute has_element?(view, "#display_token_expires_in_days")

      view
      |> form("#display-form",
        display_token: %{name: "Hall", view_ids: ["", to_string(second.id)], rotate_seconds: ""}
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/displays")
      assert render(view) =~ "Hall saved."
      assert DisplayTokens.get_token(scope, display_token.id).view_ids == [second.id]

      view |> element("#revoke-display-#{display_token.id}") |> render_click()
      assert render(view) =~ "Hall revoked."
      assert has_element?(view, "#no-displays")
      assert DisplayTokens.verify_token(token) == :error
    end

    test "shows when a display's views are no longer visible, expired and used",
         %{conn: conn, scope: scope} do
      other = user_fixture()
      shared = saved_view_fixture(other, name: "Was shared", visibility: :shared)
      {token, display_token} = display_token_fixture(scope, [shared])
      {:ok, _} = SavedViews.update_view(Scope.for_user(other), shared, %{visibility: :personal})
      {:ok, _} = DisplayTokens.verify_token(token)

      display_token
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -60))
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/settings/displays")
      assert has_element?(view, "#display-#{display_token.id} [data-hidden-view=#{shared.slug}]")
      assert has_element?(view, "#display-#{display_token.id} .badge-error", "Expired")
      assert has_element?(view, "#display-#{display_token.id}-used")
    end

    test "can't touch others' displays", %{conn: conn} do
      other = user_fixture()
      view = saved_view_fixture(other, visibility: :shared)
      {_token, theirs} = display_token_fixture(other, [view])

      assert {:error, {:live_redirect, %{to: "/settings/displays", flash: flash}}} =
               live(conn, ~p"/settings/displays/#{theirs.id}/edit")

      assert flash["error"] == "That display doesn't exist."

      {:ok, live_view, _html} = live(conn, ~p"/settings/displays")
      render_hook(live_view, "revoke", %{"id" => to_string(theirs.id)})
      assert render(live_view) =~ "That display doesn&#39;t exist."
      assert Repo.get(DisplayToken, theirs.id)
    end
  end
end
