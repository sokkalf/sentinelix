defmodule Sentinelix.Monitoring.GroupingTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Monitoring.{Grouping, Selector}
  alias Sentinelix.Monitoring.Grouping.Group

  doctest Grouping

  defp entry(id, name, labels, status, checks \\ nil) do
    %{
      monitor: %{id: id, name: name, all_labels: labels},
      status: status,
      checks: checks
    }
  end

  defp ids(%Group{entries: entries}), do: Enum.map(entries, & &1.monitor.id)

  test "every status the dashboard shows has a severity" do
    statuses = Enum.map(Selector.statuses(), &String.to_existing_atom/1)
    assert Enum.sort(Grouping.severity()) == Enum.sort(statuses)
    assert Grouping.problem_statuses() -- Grouping.severity() == []
  end

  test "no keys give one group of all entries, sorted by name" do
    entries = [entry(2, "beta", %{}, :up), entry(1, "Alpha", %{}, :down)]

    assert [%Group{id: "", key: nil, value: nil, total: 2} = group] =
             Grouping.group(entries, [])

    assert ids(group) == [1, 2]
    assert Grouping.group([], []) == []
    assert Grouping.group([], ["env"]) == []
  end

  test "groups by a key, monitors without it in a (none) group" do
    entries = [
      entry(1, "web", %{"env" => "prod"}, :up),
      entry(2, "db", %{"env" => "prod"}, :up),
      entry(3, "dev web", %{"env" => "dev"}, :up),
      entry(4, "loose", %{}, :up),
      entry(5, "flagged", %{"env" => ""}, :up)
    ]

    groups = Grouping.group(entries, ["env"], sort: :name)
    assert Enum.map(groups, & &1.id) == ["env=", "env=dev", "env=prod", "!env"]
    assert Enum.map(groups, & &1.value) == ["", "dev", "prod", nil]
    assert ids(Enum.at(groups, 2)) == [2, 1]
  end

  test "reads labels and automatic labels of unsaved monitors" do
    monitor = %{
      id: 1,
      name: "x",
      all_labels: nil,
      labels: %{"env" => "prod"},
      auto_labels: %{"type" => "tcp"}
    }

    assert [%Group{id: "type=tcp"}] = Grouping.group([%{monitor: monitor, status: :up}], ["type"])
  end

  test "nests groups by further keys" do
    entries = [
      entry(1, "a", %{"service" => "api", "site" => "oslo"}, :up),
      entry(2, "b", %{"service" => "api", "site" => "helsinki"}, :down),
      entry(3, "c", %{"service" => "web", "site" => "oslo"}, :up),
      entry(4, "d", %{"service" => "api"}, :up)
    ]

    [api, web] = Grouping.group(entries, ["service", "site"])
    assert api.id == "service=api"
    assert api.total == 3
    assert ids(api) == [1, 2, 4]

    assert Enum.map(api.groups, & &1.id) ==
             ["service=api,site=helsinki", "service=api,site=oslo", "service=api,!site"]

    assert [%Group{id: "service=web,site=oslo", groups: []}] = web.groups

    assert Enum.map(Grouping.flatten([api, web]), & &1.id) == [
             "service=api",
             "service=api,site=helsinki",
             "service=api,site=oslo",
             "service=api,!site",
             "service=web",
             "service=web,site=oslo"
           ]
  end

  test "summarizes counts, the worst status, problems and the uptime" do
    entries = [
      entry(1, "a", %{"env" => "prod"}, :up, %{up: 90, down: 10, unreachable: 0}),
      entry(2, "b", %{"env" => "prod"}, :pending, %{up: 100, down: 0, unreachable: 0}),
      entry(3, "c", %{"env" => "prod"}, :maintenance, nil),
      entry(4, "d", %{"env" => "dev"}, :paused, %{up: 0, down: 0, unreachable: 0})
    ]

    [prod, dev] = Grouping.group(entries, ["env"])

    assert prod.counts == %{
             up: 1,
             down: 0,
             unreachable: 0,
             pending: 1,
             maintenance: 1,
             paused: 0
           }

    assert prod.total == 3
    assert prod.worst == :pending
    assert prod.problems
    assert prod.uptime == 95.0

    assert dev.worst == :paused
    refute dev.problems
    assert dev.uptime == nil
  end

  test "unreachable is a problem and counts as downtime" do
    [group] =
      Grouping.group(
        [
          entry(1, "a", %{}, :unreachable, %{up: 1, down: 0, unreachable: 1}),
          entry(2, "b", %{}, :pending)
        ],
        []
      )

    assert group.worst == :unreachable
    assert group.problems
    assert group.uptime == 50.0
  end

  test "worst status ranks unknown statuses first" do
    assert Grouping.worst_status(%{up: 1, down: 1}) == :down
    assert Grouping.worst_status(%{up: 1, sideways: 1, down: 1}) == :sideways
    assert Grouping.worst_status(%{up: 0}) == nil
  end

  test "sorts problem groups first, the worst first, then by name" do
    entries = [
      entry(1, "a", %{"site" => "oslo"}, :up),
      entry(2, "b", %{"site" => "Bergen"}, :pending),
      entry(3, "c", %{"site" => "helsinki"}, :down),
      entry(4, "d", %{"site" => "alta"}, :maintenance),
      entry(5, "e", %{}, :down),
      entry(6, "f", %{"site" => "zurich"}, :pending)
    ]

    problems = Grouping.group(entries, ["site"])

    assert Enum.map(problems, & &1.value) ==
             ["helsinki", nil, "Bergen", "zurich", "alta", "oslo"]

    by_name = Grouping.group(entries, ["site"], sort: :name)
    assert Enum.map(by_name, & &1.value) == ["alta", "Bergen", "helsinki", "oslo", "zurich", nil]
  end

  test "uptime pools check counts" do
    assert Grouping.uptime(nil) == nil
    assert Grouping.uptime([]) == nil
    assert Grouping.uptime(%{up: 1, down: 1}) == 50.0
    assert Grouping.uptime([%{up: 3, down: 0, unreachable: 1}, %{up: 1, down: 0}]) == 80.0
  end
end
