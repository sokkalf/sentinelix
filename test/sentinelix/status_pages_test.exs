defmodule Sentinelix.StatusPagesTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures
  import Sentinelix.StatusPagesFixtures

  alias Sentinelix.{Monitoring, StatusPages}
  alias Sentinelix.StatusPages.{Group, StatusPage}

  describe "status pages" do
    test "create_status_page/1 derives the slug from the title" do
      assert {:ok, page} = StatusPages.create_status_page(%{title: "Acme Status – Prod!"})
      assert page.slug == "acme-status-prod"
      refute page.published
      refute page.show_details
    end

    test "create_status_page/1 validates the slug" do
      assert {:error, changeset} = StatusPages.create_status_page(%{title: "x", slug: "Not ok!"})
      assert "may only contain lowercase letters, digits and dashes" in errors_on(changeset).slug

      # case is normalized
      assert {:ok, %{slug: "acme"}} =
               StatusPages.create_status_page(%{title: "A", slug: " ACME "})

      assert {:error, changeset} = StatusPages.create_status_page(%{title: "B", slug: "acme"})
      assert "has already been taken" in errors_on(changeset).slug

      assert {:error, changeset} = StatusPages.create_status_page(%{})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "slugify/1" do
      assert StatusPage.slugify("  Hello   World ") == "hello-world"
      assert StatusPage.slugify("Ærø Status") == "r-status"
      assert StatusPage.slugify("café") == "cafe"
    end

    test "list_status_pages/0 counts distinct monitors" do
      m1 = monitor_fixture()
      m2 = monitor_fixture()
      page = status_page_fixture(%{title: "B page"})
      g1 = group_fixture(page)
      g2 = group_fixture(page)
      {:ok, _} = StatusPages.add_monitor(g1, m1)
      {:ok, _} = StatusPages.add_monitor(g2, m1)
      {:ok, _} = StatusPages.add_monitor(g2, m2)
      empty = status_page_fixture(%{title: "a page"})

      assert [%{page: %{id: first}, monitor_count: 0}, %{page: %{id: second}, monitor_count: 2}] =
               StatusPages.list_status_pages()

      assert {first, second} == {empty.id, page.id}
    end

    test "get_published_status_page_by_slug!/1 only finds published pages" do
      page = status_page_fixture(%{slug: "draft"})

      assert_raise Ecto.NoResultsError, fn ->
        StatusPages.get_published_status_page_by_slug!("draft")
      end

      assert_raise Ecto.NoResultsError, fn ->
        StatusPages.get_published_status_page_by_slug!("nope")
      end

      {:ok, _} = StatusPages.update_status_page(page, %{published: true})
      assert %{id: id, groups: []} = StatusPages.get_published_status_page_by_slug!("draft")
      assert id == page.id
    end

    test "update and delete broadcast on the page topic" do
      page = status_page_fixture()
      StatusPages.subscribe(page)
      page_id = page.id

      {:ok, page} = StatusPages.update_status_page(page, %{title: "New"})
      assert_receive {:status_page_updated, ^page_id}

      {:ok, _} = StatusPages.delete_status_page(page)
      assert_receive {:status_page_deleted, ^page_id}
    end
  end

  describe "groups and monitors" do
    test "are kept in order and can be moved" do
      page = status_page_fixture()
      StatusPages.subscribe(page)
      page_id = page.id

      g1 = group_fixture(page, %{name: "One"})
      assert_receive {:status_page_updated, ^page_id}
      g2 = group_fixture(page, %{name: "Two"})
      g3 = group_fixture(page, %{name: "Three"})

      assert names(page) == ["One", "Two", "Three"]

      :ok = StatusPages.move_group(g3, :up)
      assert names(page) == ["One", "Three", "Two"]
      :ok = StatusPages.move_group(g1, :up)
      assert names(page) == ["One", "Three", "Two"]
      :ok = StatusPages.move_group(g1, :down)
      assert names(page) == ["Three", "One", "Two"]
      :ok = StatusPages.move_group(StatusPages.get_group(page, g2.id), :down)
      assert names(page) == ["Three", "One", "Two"]

      a = monitor_fixture(:http, %{name: "A"})
      b = monitor_fixture(:http, %{name: "B"})
      {:ok, pm_a} = StatusPages.add_monitor(g1, a)
      {:ok, pm_b} = StatusPages.add_monitor(g1, b.id)
      assert monitor_names(page, g1) == ["A", "B"]

      assert {:error, changeset} = StatusPages.add_monitor(g1, a)
      assert "is already in this group" in errors_on(changeset).monitor_id

      :ok = StatusPages.move_monitor(pm_b, :up)
      assert monitor_names(page, g1) == ["B", "A"]

      {:ok, _} = StatusPages.remove_monitor(StatusPages.get_page_monitor(page, pm_a.id))
      assert monitor_names(page, g1) == ["B"]

      {:ok, _} = StatusPages.update_group(g1, %{name: "Renamed"})
      assert {:error, _} = StatusPages.update_group(g1, %{name: " "})
      {:ok, _} = StatusPages.delete_group(g2)
      assert names(page) == ["Three", "Renamed"]
    end

    test "lookups are scoped to the page" do
      page = status_page_fixture()
      other = status_page_fixture()
      group = group_fixture(other)
      {:ok, pm} = StatusPages.add_monitor(group, monitor_fixture())

      assert StatusPages.get_group(page, group.id) == nil
      assert StatusPages.get_page_monitor(page, pm.id) == nil
      assert StatusPages.get_page_monitor(other, pm.id).id == pm.id
    end

    test "deleting a monitor removes it from pages" do
      monitor = monitor_fixture()
      page = published_page_fixture([monitor])
      {:ok, _} = Monitoring.delete_monitor(monitor)
      assert [%{page_monitors: []}] = StatusPages.get_status_page!(page.id).groups
    end
  end

  describe "selector groups" do
    test "validate and normalize the selector, without status terms" do
      page = status_page_fixture()

      assert {:ok, group} =
               StatusPages.create_group(page, %{name: "Prod", selector: "Env=prod,  !legacy"})

      assert group.selector == "env=prod, !legacy"
      assert Group.kind(group) == :selector

      assert {:error, changeset} =
               StatusPages.create_group(page, %{name: "Down", selector: "status=down"})

      assert ["status can't be used here at column 1"] = errors_on(changeset).selector

      assert {:error, changeset} =
               StatusPages.create_group(page, %{name: "Bad", selector: "env=prod,"})

      assert [_parse_error] = errors_on(changeset).selector
    end

    test "never store an empty selector" do
      page = status_page_fixture()

      # a selector group needs a selector
      assert {:error, changeset} =
               StatusPages.create_group(page, %{name: "All", kind: :selector, selector: " "})

      assert ["can't be blank: an empty selector would match every monitor"] =
               errors_on(changeset).selector

      # without a kind, a blank selector is a fixed list
      assert {:ok, %{selector: nil} = group} =
               StatusPages.create_group(page, %{name: "Fixed", selector: ""})

      assert Group.kind(group) == :fixed

      # switching to a fixed list drops the selector
      {:ok, group} = StatusPages.update_group(group, %{selector: "env=prod"})
      assert Group.kind(group) == :selector
      {:ok, group} = StatusPages.update_group(group, %{kind: "fixed", selector: "env=prod"})
      assert group.selector == nil

      # renaming keeps it a selector group
      {:ok, group} = StatusPages.update_group(group, %{kind: "selector", selector: "env=prod"})
      {:ok, group} = StatusPages.update_group(group, %{name: "Renamed"})
      assert group.selector == "env=prod"

      # stored selectors that are empty or no longer parse match nothing
      monitor_fixture()
      assert Group.parsed_selector(%Group{selector: ""}) == nil
      assert Group.parsed_selector(%Group{selector: "status=down"}) == nil
      assert StatusPages.group_monitors(%Group{selector: "", page_monitors: []}) == []
    end

    test "show pinned monitors first, then the matches by name" do
      zulu = monitor_fixture(:http, %{name: "zulu", labels: %{"env" => "prod"}})
      _alpha = monitor_fixture(:http, %{name: "Alpha", labels: %{"env" => "prod"}})
      beta = monitor_fixture(:http, %{name: "beta", labels: %{"env" => "prod"}})
      pinned_other = monitor_fixture(:http, %{name: "Pinned dev", labels: %{"env" => "dev"}})
      _dev = monitor_fixture(:http, %{name: "Dev", labels: %{"env" => "dev"}})

      page = status_page_fixture()
      group = group_fixture(page, %{name: "Prod", selector: "env=prod"})
      {:ok, _} = StatusPages.add_monitor(group, zulu)
      # pinned monitors stay even when the selector doesn't match them
      {:ok, _} = StatusPages.add_monitor(group, pinned_other)

      assert member_names(page, group) == ["zulu", "Pinned dev", "Alpha", "beta"]

      # new and relabelled monitors join and leave
      gamma = monitor_fixture(:http, %{name: "Gamma", labels: %{"env" => "prod"}})
      {:ok, _} = Monitoring.delete_labels([beta], ["env"])
      assert member_names(page, group) == ["zulu", "Pinned dev", "Alpha", "Gamma"]

      # the in-memory check agrees
      loaded = Enum.find(StatusPages.get_status_page!(page.id).groups, &(&1.id == group.id))
      assert StatusPages.member?(loaded, gamma)
      refute StatusPages.member?(loaded, Monitoring.get_monitor!(beta.id))

      assert ids(StatusPages.group_monitors(loaded, Monitoring.list_monitors())) ==
               ids(loaded.monitors)

      # unpinning keeps a monitor that matches
      [pm_zulu, _pm_other] = loaded.page_monitors
      {:ok, _} = StatusPages.remove_monitor(pm_zulu)
      assert member_names(page, group) == ["Pinned dev", "Alpha", "Gamma", "zulu"]

      # name terms
      {:ok, _} = StatusPages.update_group(group, %{selector: "name~a, env"})
      assert member_names(page, group) == ["Pinned dev", "Alpha", "Gamma"]
    end

    test "count in list_status_pages/0" do
      a = monitor_fixture(:http, %{labels: %{"env" => "prod"}})
      _b = monitor_fixture(:http, %{labels: %{"env" => "prod"}})
      _c = monitor_fixture(:http, %{labels: %{"env" => "dev"}})
      page = status_page_fixture()
      group_fixture(page, %{selector: "env=prod"})
      fixed = group_fixture(page)
      {:ok, _} = StatusPages.add_monitor(fixed, a)
      other = status_page_fixture()
      group_fixture(other, %{selector: "env=prod"})
      group_fixture(other, %{selector: "env in (prod,dev)"})

      counts = Map.new(StatusPages.list_status_pages(), &{&1.page.id, &1.monitor_count})
      assert counts == %{page.id => 2, other.id => 3}
    end
  end

  describe "public data" do
    test "open incidents and recent incidents" do
      m1 = monitor_fixture()
      m2 = monitor_fixture()
      m3 = monitor_fixture()
      open = incident_fixture(m1)
      old = incident_fixture(m2, %{started_at: DateTime.add(DateTime.utc_now(), -20, :day)})

      {:ok, _} =
        Monitoring.resolve_incident(old, resolved_at: DateTime.add(DateTime.utc_now(), -10, :day))

      recent = incident_fixture(m2)
      {:ok, _} = Monitoring.resolve_incident(recent)
      _other = incident_fixture(m3)

      # Warning incidents are internal.
      _warning = incident_fixture(m2, %{to_status: :warning})

      assert StatusPages.open_incident_monitor_ids([m1.id, m2.id]) == MapSet.new([m1.id])

      since = DateTime.add(DateTime.utc_now(), -7, :day)
      ids = [m1.id, m2.id] |> StatusPages.recent_incidents(since) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([open.id, recent.id])
    end

    test "public_status/1" do
      status = &StatusPages.public_status/1
      base = %{enabled: true, latest_status: :up, incident?: false}

      assert status.(%{base | enabled: false, latest_status: :down}) == :paused
      assert status.(base) == :operational
      assert status.(%{base | incident?: true}) == :degraded
      assert status.(%{base | latest_status: :pending}) == :degraded
      assert status.(%{base | latest_status: :warning}) == :degraded
      assert status.(%{base | latest_status: :down}) == :outage
      assert status.(%{base | latest_status: :unreachable}) == :unreachable
      assert status.(%{base | latest_status: :maintenance}) == :maintenance
      assert status.(Map.merge(base, %{latest_status: :down, maintenance?: true})) == :maintenance
      assert status.(%{base | latest_status: nil}) == :unknown
      assert status.(%{base | latest_status: nil, incident?: true}) == :degraded
    end

    test "overall_status/1" do
      overall = &StatusPages.overall_status/1

      assert overall.([]) == :operational
      assert overall.([:operational, :paused, :unknown]) == :operational
      assert overall.([:operational, :degraded]) == :degraded
      assert overall.([:operational, :outage]) == :partial_outage
      assert overall.([:outage, :outage, :maintenance, :paused]) == :major_outage
      assert overall.([:operational, :unreachable]) == :partial_outage
      assert overall.([:outage, :unreachable]) == :major_outage
      assert overall.([:operational, :maintenance]) == :maintenance
      assert overall.([:maintenance]) == :maintenance
    end
  end

  defp names(page), do: Enum.map(StatusPages.get_status_page!(page.id).groups, & &1.name)

  defp monitor_names(page, group) do
    page.id
    |> StatusPages.get_status_page!()
    |> Map.fetch!(:groups)
    |> Enum.find(&(&1.id == group.id))
    |> Map.fetch!(:page_monitors)
    |> Enum.map(& &1.monitor.name)
  end

  defp ids(monitors), do: Enum.map(monitors, & &1.id)

  # The group's monitors in display order (pinned and matched).
  defp member_names(page, group) do
    page.id
    |> StatusPages.get_status_page!()
    |> Map.fetch!(:groups)
    |> Enum.find(&(&1.id == group.id))
    |> Map.fetch!(:monitors)
    |> Enum.map(& &1.name)
  end
end
