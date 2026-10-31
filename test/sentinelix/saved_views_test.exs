defmodule Sentinelix.SavedViewsTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.AccountsFixtures
  import Sentinelix.SavedViewsFixtures

  alias Sentinelix.Accounts.Scope
  alias Sentinelix.Monitoring.{Selector, View}
  alias Sentinelix.SavedViews
  alias Sentinelix.SavedViews.SavedView

  defp scope(groups \\ []), do: oidc_user_fixture(%{groups: groups}) |> Scope.for_user()

  defp view(params) do
    {:ok, view} = View.from_params(params)
    view
  end

  describe "create_view/3" do
    test "stores the view as its URL parameters" do
      scope = scope()

      assert {:ok, saved} =
               SavedViews.create_view(
                 scope,
                 view(%{"selector" => "env=prod", "group" => "site", "sort" => "name"}),
                 %{"name" => " Production "}
               )

      assert saved.name == "Production"
      assert saved.slug == "production"
      assert saved.visibility == :personal
      assert saved.owner_id == scope.user.id
      assert saved.params == %{"selector" => "env=prod", "group" => "site", "sort" => "name"}

      assert {:ok, %View{group_by: ["site"], sort: :name}} = SavedViews.to_view(saved)
      assert SavedViews.same_view?(saved, view(saved.params))
      refute SavedViews.same_view?(saved, %View{})
    end

    test "gives every view a unique slug" do
      scope = scope()

      slugs =
        for name <- ["Prod", "prod", "PROD!", "Prod 2", "!!!"] do
          {:ok, saved} = SavedViews.create_view(scope, %View{}, %{name: name})
          saved.slug
        end

      assert slugs == ["prod", "prod-2", "prod-3", "prod-2-2", "view"]
    end

    test "requires a name" do
      assert {:error, changeset} = SavedViews.create_view(scope(), %View{}, %{name: " "})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "puts new views after the owner's others" do
      scope = scope()
      first = saved_view_fixture(scope)
      second = saved_view_fixture(scope)
      _others = saved_view_fixture(scope())

      assert {first.position, second.position} == {0, 1}
    end

    test "group views need groups the user is a member of" do
      scope = scope(["ops", "dev"])

      assert {:error, changeset} =
               SavedViews.create_view(scope, %View{}, %{name: "x", visibility: :groups})

      assert %{groups: ["pick at least one group"]} = errors_on(changeset)

      assert {:error, changeset} =
               SavedViews.create_view(scope, %View{}, %{
                 name: "x",
                 visibility: :groups,
                 groups: ["ops", "admins"]
               })

      assert %{groups: ["you can only choose groups you are a member of"]} =
               errors_on(changeset)

      assert {:ok, saved} =
               SavedViews.create_view(scope, %View{}, %{
                 name: "x",
                 visibility: :groups,
                 groups: ["ops", "", "dev", "ops"]
               })

      assert saved.groups == ["dev", "ops"]
    end

    test "only group views keep groups" do
      scope = scope(["ops"])

      {:ok, saved} =
        SavedViews.create_view(scope, %View{}, %{name: "x", visibility: :shared, groups: ["ops"]})

      assert saved.groups == []
    end

    test "local users have no groups to scope to" do
      scope = Scope.for_user(user_fixture())

      assert {:error, changeset} =
               SavedViews.create_view(scope, %View{}, %{
                 name: "x",
                 visibility: :groups,
                 groups: ["ops"]
               })

      assert errors_on(changeset).groups
    end
  end

  describe "visibility" do
    setup do
      owner = scope(["ops"])

      views = %{
        personal: saved_view_fixture(owner, name: "Personal"),
        shared: saved_view_fixture(owner, name: "Shared", visibility: :shared),
        ops: saved_view_fixture(owner, name: "Ops", visibility: :groups, groups: ["ops"])
      }

      %{owner: owner, views: views}
    end

    test "the owner sees all their views", %{owner: owner, views: views} do
      assert SavedViews.list_views(owner) |> Enum.map(& &1.id) ==
               Enum.map([views.personal, views.shared, views.ops], & &1.id)

      for {_key, view} <- views do
        assert SavedViews.get_view(owner, view.slug).id == view.id
        assert SavedViews.visible?(owner, view)
      end
    end

    test "others see shared views and views of their groups", %{views: views} do
      in_ops = scope(["ops", "dev"])
      outside = scope(["dev"])
      local = Scope.for_user(user_fixture())

      assert in_ops |> SavedViews.list_views() |> Enum.map(& &1.name) == ["Ops", "Shared"]
      assert outside |> SavedViews.list_views() |> Enum.map(& &1.name) == ["Shared"]
      assert local |> SavedViews.list_views() |> Enum.map(& &1.name) == ["Shared"]

      assert SavedViews.get_view(in_ops, views.ops.slug)
      refute SavedViews.get_view(in_ops, views.personal.slug)
      refute SavedViews.get_view(outside, views.ops.slug)
      refute SavedViews.get_view(local, views.ops.slug)
      assert SavedViews.get_view(local, views.shared.slug)

      refute SavedViews.visible?(outside, views.ops)
      refute SavedViews.visible?(in_ops, views.personal)
    end

    test "others can't change, move or delete views they see or not", %{views: views} do
      other = scope(["ops"])

      for {_key, view} <- views do
        refute SavedViews.owner?(other, view)
        assert SavedViews.update_view(other, view, %{name: "Mine"}) == {:error, :forbidden}

        assert SavedViews.update_view_params(other, view, view(%{"group" => "site"})) ==
                 {:error, :forbidden}

        assert SavedViews.move_view(other, view, :up) == {:error, :forbidden}
        assert SavedViews.delete_view(other, view) == {:error, :forbidden}
        assert Repo.reload!(view) == view
      end
    end

    test "loads a view for display without a scope", %{views: views} do
      assert SavedViews.get_view_for_display(views.personal.slug).id == views.personal.id
      refute SavedViews.get_view_for_display("nope")
    end
  end

  describe "changing views" do
    test "the owner renames a view, keeping the slug" do
      owner = scope()
      view = saved_view_fixture(owner, name: "Prod")

      assert {:ok, renamed} = SavedViews.update_view(owner, view, %{name: "Production"})
      assert {renamed.name, renamed.slug} == {"Production", "prod"}
    end

    test "the owner keeps groups they've left but can't add others" do
      owner = scope(["ops", "dev"])
      view = saved_view_fixture(owner, visibility: :groups, groups: ["ops"])
      owner = %{owner | groups: ["dev"]}

      assert {:ok, view} = SavedViews.update_view(owner, view, %{groups: ["ops", "dev"]})
      assert view.groups == ["dev", "ops"]

      assert {:error, changeset} = SavedViews.update_view(owner, view, %{groups: ["admins"]})
      assert errors_on(changeset).groups
    end

    test "updates the stored view" do
      owner = scope()
      saved = saved_view_fixture(owner, params: %{"group" => "site"})

      assert {:ok, saved} =
               SavedViews.update_view_params(owner, saved, view(%{"selector" => "env=prod"}))

      assert saved.params == %{"selector" => "env=prod"}
    end

    test "deletes a view" do
      owner = scope()
      view = saved_view_fixture(owner)

      assert {:ok, _view} = SavedViews.delete_view(owner, view)
      refute SavedViews.get_view(owner, view.slug)
    end

    test "moves the owner's views" do
      owner = scope()
      [a, b, c] = for name <- ~w(a b c), do: saved_view_fixture(owner, name: name)
      names = fn -> owner |> SavedViews.list_views() |> Enum.map(& &1.name) end

      assert {:ok, _views} = SavedViews.move_view(owner, c, :up)
      assert names.() == ~w(a c b)

      assert {:ok, _views} = SavedViews.move_view(owner, a, :down)
      assert names.() == ~w(c a b)

      assert {:ok, _views} = SavedViews.move_view(owner, b, :down)
      assert {:ok, _views} = SavedViews.move_view(owner, Repo.reload!(c), :up)
      assert names.() == ~w(c a b)
    end

    test "others' views come after the user's own, by name" do
      owner = scope()
      other = scope()
      saved_view_fixture(other, name: "zed", visibility: :shared)
      saved_view_fixture(other, name: "Alpha", visibility: :shared)
      saved_view_fixture(owner, name: "Mine")

      assert owner |> SavedViews.list_views() |> Enum.map(& &1.name) == ~w(Mine Alpha zed)
    end

    test "broadcasts changes" do
      SavedViews.subscribe()
      owner = scope()
      view = saved_view_fixture(owner)
      assert_receive {:saved_views_changed}

      SavedViews.delete_view(owner, view)
      assert_receive {:saved_views_changed}
    end
  end

  describe "stored selectors" do
    test "keep matching when label keys disappear" do
      owner = scope()
      saved = saved_view_fixture(owner, params: %{"selector" => "gone=key"})

      assert {:ok, view} = SavedViews.to_view(saved)
      refute Selector.empty?(view.selector)
    end

    test "that no longer parse still load, with the error" do
      owner = scope()
      saved = saved_view_fixture(owner, params: %{"group" => "site"})

      {1, _} =
        Repo.update_all(from(v in SavedView, where: v.id == ^saved.id),
          set: [params: %{"selector" => "env=(", "group" => "site"}]
        )

      saved = SavedViews.get_view(owner, saved.slug)
      assert {:error, view, "env=(", _error} = SavedViews.to_view(saved)
      assert view.group_by == ["site"]
      assert view.selector == nil
    end
  end

  describe "default view" do
    test "is a view the user sees, until they no longer do" do
      owner = scope(["ops"])
      user = scope(["ops"])
      view = saved_view_fixture(owner, visibility: :groups, groups: ["ops"])

      assert {:ok, updated} = SavedViews.set_default_view(user, view)
      user = Scope.for_user(updated)
      assert SavedViews.default_view(user).id == view.id

      SavedViews.update_view(owner, view, %{visibility: :personal})
      refute SavedViews.default_view(user)

      assert {:ok, updated} = SavedViews.set_default_view(user, nil)
      assert updated.default_view_id == nil
    end

    test "can't be a view the user doesn't see" do
      view = saved_view_fixture(scope())
      assert SavedViews.set_default_view(scope(), view) == {:error, :not_found}
    end

    test "is cleared when the view is deleted" do
      owner = scope()
      view = saved_view_fixture(owner)
      {:ok, user} = SavedViews.set_default_view(owner, view)

      SavedViews.delete_view(owner, view)
      assert Repo.reload!(user).default_view_id == nil
    end
  end
end
