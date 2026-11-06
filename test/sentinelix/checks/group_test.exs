defmodule Sentinelix.Checks.GroupTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Checks.Group
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{CheckResult, Monitor}

  defp group_fixture(members \\ "app=shop", attrs \\ %{}) do
    {settings, attrs} = Map.pop(attrs, :settings, %{})
    monitor_fixture(:group, Map.put(attrs, :settings, Map.put(settings, :members, members)))
  end

  defp member_fixture(name, labels \\ %{"app" => "shop"}, type \\ :tcp) do
    monitor_fixture(type, %{name: name, labels: labels})
  end

  describe "settings" do
    test "require a valid members selector without status terms" do
      assert {:error, changeset} =
               Monitoring.create_monitor(valid_monitor_attrs(:group, %{settings: %{}}))

      assert %{settings: %{members: ["can't be blank"]}} = errors_on(changeset)

      assert {:error, changeset} =
               Monitoring.create_monitor(
                 valid_monitor_attrs(:group, %{settings: %{members: "status=down"}})
               )

      assert %{settings: %{members: ["status can't be used here at column 1"]}} =
               errors_on(changeset)
    end

    test "normalize the selector and default alert_through_group to false" do
      group = group_fixture(" App=shop ,  name~web ")

      assert group.settings.members == "app=shop, name~web"
      assert group.settings.alert_through_group == false
      assert group.auto_labels == %{"type" => "group"}
    end
  end

  describe "list_group_members/1" do
    test "returns the matching monitors, but no groups and not the group itself" do
      web = member_fixture("Web")
      db = member_fixture("DB", %{"app" => "shop"}, :postgres)
      _other = member_fixture("Other", %{"app" => "blog"})
      _group = group_fixture("app=shop", %{labels: %{"app" => "shop"}})
      group = group_fixture("app=shop", %{labels: %{"app" => "shop"}})

      assert group |> Monitoring.list_group_members() |> Enum.map(& &1.id) == [db.id, web.id]
    end

    test "is empty for other monitors" do
      assert Monitoring.list_group_members(member_fixture("Web")) == []
    end
  end

  describe "list_groups_of/2 and alerts_through_group?/1" do
    test "find the groups a monitor is a member of" do
      web = member_fixture("Web")
      quiet = group_fixture("app=shop", %{name: "Shop", settings: %{alert_through_group: true}})
      loud = group_fixture("name~web", %{name: "Webs"})
      _other = group_fixture("app=blog")

      assert web |> Monitoring.list_groups_of() |> Enum.map(& &1.id) == [quiet.id, loud.id]

      assert web |> Monitoring.list_groups_of(alert_through_group: true) |> Enum.map(& &1.id) ==
               [quiet.id]

      assert Monitoring.list_groups_of(quiet) == []
      assert Monitoring.alerts_through_group?(web)

      {:ok, _quiet} = Monitoring.toggle_monitor(quiet)
      refute Monitoring.alerts_through_group?(web)
      refute Monitoring.alerts_through_group?(member_fixture("DB", %{"app" => "blog"}))
    end
  end

  describe "run/1" do
    test "reports the worst status of the members from their latest results" do
      group = group_fixture()
      web = member_fixture("Web")
      db = member_fixture("DB")

      check_result_fixture(web, status: :down)
      check_result_fixture(web, status: :up)
      check_result_fixture(db, status: :up)

      assert {:up, %{message: "All 2 members up", response_time_ms: nil, meta: meta}} =
               Group.run(group)

      assert Enum.sort(meta.members) == Enum.sort([web.id, db.id])

      check_result_fixture(db, status: :down)
      assert {:down, %{message: "1 of 2 members down: DB"}} = Group.run(group)
    end

    test "is down when the selector matches nothing" do
      assert {:down, %{message: "No monitors match the members selector"}} =
               Group.run(group_fixture("app=nothing"))
    end
  end

  describe "aggregate/1" do
    defp member(name, status, enabled \\ true) do
      {%Monitor{id: System.unique_integer([:positive]), name: name, enabled: enabled},
       status && %CheckResult{status: status}}
    end

    test "down and unreachable members take the group down" do
      assert {:down, %{message: "2 of 3 members down: A, B"}} =
               Group.aggregate([member("A", :down), member("B", :unreachable), member("C", :up)])
    end

    test "a warning is up with a warning" do
      assert {:up, %{warning: true, message: "1 of 2 members with a warning: A"}} =
               Group.aggregate([member("A", :warning), member("B", :up)])

      assert {:down, details} = Group.aggregate([member("A", :warning), member("B", :down)])
      refute Map.has_key?(details, :warning)
    end

    test "pending members count as up" do
      assert {:up, %{message: "1 of 2 members up, 1 retrying: A"} = details} =
               Group.aggregate([member("A", :pending), member("B", :up)])

      refute Map.has_key?(details, :warning)
    end

    test "ignores paused members, members in maintenance and members without results" do
      members = [
        member("A", :down, false),
        member("B", :maintenance),
        member("C", nil),
        member("D", :up)
      ]

      assert {:up, %{message: "1 member up", meta: %{members: [_id]}}} = Group.aggregate(members)

      assert {:up, %{message: "No active members", meta: %{members: []}}} =
               Group.aggregate([member("A", :down, false), member("B", :maintenance)])
    end

    test "lists at most five names" do
      members = for name <- ~w(A B C D E F G), do: member(name, :down)

      assert {:down, %{message: "7 of 7 members down: A, B, C, D, E and 2 more"}} =
               Group.aggregate(members)
    end
  end
end
