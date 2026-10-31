defmodule SentinelixWeb.SavedViewLiveTest do
  # Not async: saving views and creating monitors broadcast on global
  # topics, which other (async) tests subscribe to.
  use SentinelixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Sentinelix.AccountsFixtures
  import Sentinelix.MonitoringFixtures
  import Sentinelix.SavedViewsFixtures

  alias Sentinelix.Accounts.Scope
  alias Sentinelix.Repo
  alias Sentinelix.SavedViews
  alias Sentinelix.SavedViews.SavedView

  # A logged in OIDC user in the groups.
  defp log_in(conn, groups) do
    user = oidc_user_fixture(%{groups: groups})
    {log_in_user(conn, user), Scope.for_user(user)}
  end

  setup %{conn: conn} do
    {conn, scope} = log_in(conn, ["ops", "dev"])
    %{conn: conn, scope: scope, user: scope.user}
  end

  describe "saving views on the dashboard" do
    test "saves the current view", %{conn: conn, user: user} do
      monitor_fixture(:http, %{name: "Web", labels: %{"env" => "prod", "site" => "osl"}})
      {:ok, view, _html} = live(conn, ~p"/?#{[selector: "env=prod", group: "site"]}")

      refute has_element?(view, "#save-view-form")
      view |> element("#save-view") |> render_click()

      view
      |> form("#save-view-form", saved_view: %{name: "Production", visibility: "groups"})
      |> render_change()

      assert has_element?(view, "#save-view-form input[type=checkbox][value=ops]")

      view
      |> form("#save-view-form",
        saved_view: %{name: "Production", visibility: "groups", groups: ["ops"]},
        default: "true"
      )
      |> render_submit()

      assert_patch(view, ~p"/views/production")
      assert render(view) =~ "View &quot;Production&quot; saved."

      saved = Repo.get_by!(SavedView, slug: "production")
      assert saved.params == %{"selector" => "env=prod", "group" => "site"}
      assert {saved.visibility, saved.groups, saved.owner_id} == {:groups, ["ops"], user.id}
      assert Repo.reload!(user).default_view_id == saved.id

      assert has_element?(view, "h1", "Production")
      assert has_element?(view, "#saved-view-info", "ops")
      assert has_element?(view, "#toggle-default", "Default")
      assert has_element?(view, "#nav-view-production a[aria-current=page]", "Production")
    end

    test "saves and shows the layout", %{conn: conn} do
      monitor_fixture(:http, %{name: "Web", labels: %{"site" => "osl"}})
      {:ok, view, _html} = live(conn, ~p"/?#{[group: "site", layout: "grid"]}")

      view |> element("#save-view") |> render_click()
      view |> form("#save-view-form", saved_view: %{name: "Tiles"}) |> render_submit()

      assert_patch(view, ~p"/views/tiles")

      assert Repo.get_by!(SavedView, slug: "tiles").params == %{
               "group" => "site",
               "layout" => "grid"
             }

      {:ok, view, _html} = live(conn, ~p"/views/tiles")
      assert has_element?(view, "#layout option[value=grid][selected]")
    end

    test "shows errors and only offers the user's groups", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#save-view") |> render_click()

      html =
        view
        |> form("#save-view-form", saved_view: %{name: "", visibility: "groups"})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute Repo.exists?(SavedView)

      # Groups the user isn't in, sent anyway.
      view
      |> render_submit("save_view", %{
        "saved_view" => %{"name" => "x", "visibility" => "groups", "groups" => ["admins"]}
      })

      refute Repo.exists?(SavedView)
      assert render(view) =~ "you can only choose groups you are a member of"

      view |> element("#cancel-save") |> render_click()
      refute has_element?(view, "#save-view-form")
    end

    test "local users can't scope views to groups", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#save-view") |> render_click()

      refute has_element?(view, "#save-view-form option[value=groups]")
    end

    test "can't save a view whose selector doesn't parse", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?#{[selector: "env=("]}")

      assert has_element?(view, "#save-view[disabled]")
      render_click(view, "new_view")
      render_submit(view, "save_view", %{"saved_view" => %{"name" => "Broken"}})

      refute Repo.exists?(SavedView)
    end
  end

  describe "a saved view on the dashboard" do
    setup %{scope: scope} do
      monitor_fixture(:http, %{name: "Prod web", labels: %{"env" => "prod", "site" => "osl"}})
      monitor_fixture(:http, %{name: "Dev web", labels: %{"env" => "dev", "site" => "osl"}})
      %{saved: saved_view_fixture(scope, name: "Prod", params: %{"selector" => "env=prod"})}
    end

    test "shows the stored view", %{conn: conn, saved: saved} do
      {:ok, view, html} = live(conn, ~p"/views/#{saved.slug}")

      assert html =~ "Prod web"
      refute html =~ "Dev web"
      assert has_element?(view, "#selector[value='env=prod']")
      refute has_element?(view, "#view-modified")
      refute has_element?(view, "#update-view")
      assert has_element?(view, "#edit-view")
    end

    test "changes stay on the view until it's updated or reset", %{conn: conn, saved: saved} do
      {:ok, view, _html} = live(conn, ~p"/views/#{saved.slug}")

      view |> form("#filter-form", %{selector: "env=prod", group: ["site"]}) |> render_change()
      assert_patch(view, ~p"/views/prod?#{[selector: "env=prod", group: "site"]}")
      assert has_element?(view, "#view-modified")

      # Label badges and status counters keep to the view's path.
      assert has_element?(view, "[data-label='site=osl'][href^='/views/prod?']")
      assert has_element?(view, "#counter-up[href^='/views/prod?']")

      view |> element("#reset-view") |> render_click()
      assert_patch(view, ~p"/views/prod")
      refute has_element?(view, "#view-modified")

      view |> form("#filter-form", %{selector: "", group: [""]}) |> render_change()
      assert_patch(view, ~p"/views/prod?#{[selector: ""]}")
      assert render(view) =~ "Dev web"

      view |> element("#update-view") |> render_click()
      assert_patch(view, ~p"/views/prod")
      assert Repo.reload!(saved).params == %{}
    end

    test "changing it back to the stored view isn't a change", %{conn: conn, saved: saved} do
      {:ok, view, _html} = live(conn, ~p"/views/#{saved.slug}?#{[selector: "env=dev"]}")
      assert has_element?(view, "#view-modified")

      view |> form("#filter-form", %{selector: "env=prod"}) |> render_change()
      assert_patch(view, ~p"/views/prod")
      refute has_element?(view, "#view-modified")
    end

    test "saves a changed view as a new one", %{conn: conn, saved: saved} do
      {:ok, view, _html} = live(conn, ~p"/views/#{saved.slug}?#{[selector: "env=dev"]}")

      assert has_element?(view, "#save-view", "Save as new view")
      view |> element("#save-view") |> render_click()
      view |> form("#save-view-form", saved_view: %{name: "Dev"}) |> render_submit()

      assert_patch(view, ~p"/views/dev")
      assert Repo.reload!(saved).params == %{"selector" => "env=prod"}
      assert Repo.get_by!(SavedView, slug: "dev").params == %{"selector" => "env=dev"}
    end

    test "a stored selector that no longer parses shows its error", %{conn: conn, saved: saved} do
      Repo.update_all(SavedView, set: [params: %{"selector" => "env=("}])

      {:ok, view, html} = live(conn, ~p"/views/#{saved.slug}")

      assert has_element?(view, "#selector[value='env=(']")
      assert html =~ "No monitors match"
      assert has_element?(view, "#save-view[disabled]")
    end

    test "makes it the default view and back", %{conn: conn, saved: saved, user: user} do
      {:ok, view, _html} = live(conn, ~p"/views/#{saved.slug}")

      view |> element("#toggle-default") |> render_click()
      assert Repo.reload!(user).default_view_id == saved.id
      assert has_element?(view, "#toggle-default", "Default")
      assert has_element?(view, "#nav-view-prod [data-role=default]")

      view |> element("#toggle-default") |> render_click()
      assert Repo.reload!(user).default_view_id == nil
      assert has_element?(view, "#toggle-default", "Make default")
    end

    test "an unknown view redirects to the dashboard", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/?selector=", flash: flash}}} =
               live(conn, ~p"/views/nope")

      assert flash["error"] =~ "doesn't exist"
    end
  end

  describe "the default view" do
    setup %{scope: scope} do
      monitor_fixture(:http, %{name: "Prod web", labels: %{"env" => "prod"}})
      monitor_fixture(:http, %{name: "Dev web", labels: %{"env" => "dev"}})
      saved = saved_view_fixture(scope, name: "Prod", params: %{"selector" => "env=prod"})
      {:ok, _user} = SavedViews.set_default_view(scope, saved)
      %{saved: saved}
    end

    test "is shown at /", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/views/prod"}}} = live(conn, ~p"/")
      {:ok, view, html} = live(conn, ~p"/views/prod")
      refute html =~ "Dev web"

      # The unfiltered dashboard is still a click away.
      view |> element("#show-all") |> render_click()
      assert_patch(view, ~p"/?#{[selector: ""]}")
      assert render(view) =~ "Dev web"
      assert has_element?(view, "h1", "Dashboard")

      # Clearing everything there keeps showing everything.
      view |> form("#filter-form", %{selector: "env=dev"}) |> render_change()
      assert_patch(view, ~p"/?#{[selector: "env=dev"]}")
      view |> form("#filter-form", %{selector: ""}) |> render_change()
      assert_patch(view, ~p"/?#{[selector: ""]}")
    end

    test "is ignored once the user no longer sees it", %{conn: conn, saved: saved} do
      {conn, scope} = log_in(conn, ["ops"])
      saved = Repo.update!(Ecto.Changeset.change(saved, visibility: :groups, groups: ["ops"]))
      {:ok, _user} = SavedViews.set_default_view(scope, saved)

      Repo.update!(Ecto.Changeset.change(saved, groups: ["dev"]))
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Dev web"
    end
  end

  describe "views of other users" do
    setup do
      owner = Scope.for_user(oidc_user_fixture(%{groups: ["ops", "admins"]}))

      %{
        personal: saved_view_fixture(owner, name: "Personal"),
        shared: saved_view_fixture(owner, name: "Shared", visibility: :shared),
        ops: saved_view_fixture(owner, name: "Ops", visibility: :groups, groups: ["ops"]),
        admins: saved_view_fixture(owner, name: "Admins", visibility: :groups, groups: ["admins"])
      }
    end

    test "the sidebar lists the views the user sees", %{conn: conn, scope: scope} do
      saved_view_fixture(scope, name: "Mine")
      {:ok, view, _html} = live(conn, ~p"/monitors")

      names =
        view
        |> element("#saved-views-nav")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("li[id^=nav-view-]")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&String.trim/1)

      assert names == ["Mine", "Ops", "Shared"]
      assert has_element?(view, "#nav-manage-views[href='/views']")
    end

    test "the sidebar follows changes", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/monitors")
      refute has_element?(view, "#nav-view-mine")

      saved = saved_view_fixture(scope, name: "Mine")
      assert has_element?(view, "#nav-view-mine")

      SavedViews.delete_view(scope, saved)
      refute has_element?(view, "#nav-view-mine")
    end

    test "can't be opened when not shared with the user", %{conn: conn} = views do
      for key <- [:personal, :admins] do
        assert {:error, {:live_redirect, %{to: "/?selector="}}} =
                 live(conn, ~p"/views/#{views[key].slug}")

        assert {:error, {:live_redirect, %{to: "/views"}}} =
                 live(conn, ~p"/views/#{views[key].slug}/edit")
      end
    end

    test "shared views open but can't be changed", %{conn: conn} = views do
      for key <- [:shared, :ops] do
        saved = views[key]
        {:ok, view, _html} = live(conn, ~p"/views/#{saved.slug}?#{[group: "env"]}")

        assert has_element?(view, "#view-modified")
        refute has_element?(view, "#update-view")
        refute has_element?(view, "#edit-view")

        render_click(view, "update_view")
        assert render(view) =~ "Only the owner of a view can change it."
        assert Repo.reload!(saved) == saved |> Map.put(:owner, saved.owner)

        assert {:error, {:live_redirect, %{to: "/views"}}} =
                 live(conn, ~p"/views/#{saved.slug}/edit")
      end
    end

    test "the views page lists them without owner actions", %{conn: conn} = views do
      {:ok, view, _html} = live(conn, ~p"/views")

      assert has_element?(view, "#saved-view-shared")
      assert has_element?(view, "#saved-view-ops")
      refute has_element?(view, "#saved-view-personal")
      refute has_element?(view, "#saved-view-admins")
      refute has_element?(view, "#delete-shared")
      refute has_element?(view, "#edit-ops")

      # Events sent anyway change nothing.
      for key <- [:shared, :ops, :personal, :admins] do
        saved = Repo.reload!(views[key])

        message =
          if key in [:shared, :ops],
            do: "Only the owner of a view can change it.",
            else: "doesn&#39;t exist or isn&#39;t shared with you"

        assert render_click(view, "delete", %{"slug" => saved.slug}) =~ message
        render_click(view, "move", %{"slug" => saved.slug, "direction" => "up"})
        assert Repo.reload!(saved) == saved
      end
    end

    test "can be the user's default view when shared with them",
         %{conn: conn, user: user} = views do
      {:ok, view, _html} = live(conn, ~p"/views")

      view |> element("#default-ops") |> render_click()
      assert Repo.reload!(user).default_view_id == views.ops.id

      render_click(view, "toggle_default", %{"slug" => views.admins.slug})
      assert Repo.reload!(user).default_view_id == views.ops.id
      assert render(view) =~ "doesn&#39;t exist or isn&#39;t shared with you"
    end
  end

  describe "the views page" do
    test "renames, reorders and deletes the user's views", %{conn: conn, scope: scope} do
      for name <- ~w(One Two), do: saved_view_fixture(scope, name: name)
      {:ok, view, _html} = live(conn, ~p"/views")

      view |> element("#move-down-one") |> render_click()
      assert scope |> SavedViews.list_views() |> Enum.map(& &1.name) == ~w(Two One)

      view |> element("#edit-one") |> render_click()
      assert_patch(view, ~p"/views/one/edit")

      view
      |> form("#saved-view-form", saved_view: %{name: "First", visibility: "groups"})
      |> render_change()

      html =
        view
        |> form("#saved-view-form",
          saved_view: %{name: "First", visibility: "groups", groups: ["dev"]}
        )
        |> render_submit()

      assert_patch(view, ~p"/views")
      assert html =~ "View &quot;First&quot; saved."
      assert %{name: "First", groups: ["dev"]} = SavedViews.get_view(scope, "one")
      assert has_element?(view, "#nav-view-one", "First")

      view |> element("#delete-two") |> render_click()
      refute SavedViews.get_view(scope, "two")
      refute has_element?(view, "#saved-view-two")
    end

    test "shows an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/views")
      assert has_element?(view, "#no-saved-views")
    end
  end
end
