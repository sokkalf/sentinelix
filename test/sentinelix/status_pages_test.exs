defmodule Sentinelix.StatusPagesTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures
  import Sentinelix.StatusPagesFixtures

  alias Sentinelix.{Monitoring, StatusPages}
  alias Sentinelix.StatusPages.StatusPage

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
end
