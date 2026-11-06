defmodule Sentinelix.Checks.Group do
  @moduledoc """
  Group check: the combined status of other monitors, e.g. the ports and
  the database of one application.

  A group monitor doesn't probe anything itself. Its members are the
  monitors its `members` selector (labels and name, e.g. `app=shop`)
  matches, see `Sentinelix.Monitoring.list_group_members/1`; groups are
  never members. Each check reads the members' latest check results and
  reports the worst of them:

    * a member that is `:down` or `:unreachable` → the group is down,
    * otherwise a member with a `:warning` → up with a warning,
    * otherwise up (members that are `:pending`, still retrying, count as
      up until they go down).

  Paused members, members in maintenance and members without a check
  result yet are left out. A group without any member to count is up;
  a selector that matches no monitor at all is reported as down, so a
  mistyped selector doesn't pass for a healthy group.

  Only warnings that are a status (raised by events, see
  `Sentinelix.Monitoring.Events`) are seen: a check's warning (e.g. a TLS
  certificate close to expiry) isn't stored with the result.

  The check runs every `interval_seconds` like any other, and right away
  (debounced) when a member's status changes or a monitor is changed, see
  `subscribe/1` and `recheck?/2`. The status machine of the group (retries,
  incidents, notifications, maintenance, its own parent) is the worker's,
  as for every monitor.

  Unreachable members count as down. To keep a group quiet while the host
  its members run on is down, give the group a parent too (e.g. the ping
  monitor of the host).
  """

  @behaviour Sentinelix.Checks.Check

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{CheckResult, Monitor}

  @failing [:down, :unreachable]
  @ignored [:maintenance]
  # Names listed in a result message before "and n more".
  @max_names 5

  @impl true
  def run(%Monitor{} = group) do
    members = Monitoring.list_group_members(group)
    latest = members |> Enum.map(& &1.id) |> Monitoring.latest_result_per_monitor()

    members
    |> Enum.map(&{&1, latest[&1.id]})
    |> aggregate()
  end

  @impl true
  def subscribe(%Monitor{}) do
    :ok = Monitoring.subscribe_status_changes()
    :ok = Monitoring.subscribe_monitors()
  end

  @impl true
  def recheck?(group, {:status_changed, monitor, _old, _new, _result}),
    do: Monitoring.group_member?(group, monitor)

  def recheck?(group, {event, monitor, _result})
      when event in [:warning_raised, :warning_cleared],
      do: Monitoring.group_member?(group, monitor)

  # A monitor that joins or leaves the group, or a member that is paused
  # or resumed. Not known which monitors were members before a change, so
  # every change of a monitor that can be a member counts.
  def recheck?(%Monitor{id: id}, {event, %Monitor{id: other, type: type}})
      when event in [:monitor_created, :monitor_updated, :monitor_deleted],
      do: type != :group and other != id

  def recheck?(_group, _message), do: false

  @doc """
  The check result of a group from its members, each with its latest
  check result (or `nil`), see the moduledoc.
  """
  @spec aggregate([{Monitor.t(), CheckResult.t() | nil}]) :: Sentinelix.Checks.Check.result()
  def aggregate([]), do: result(:down, "No monitors match the members selector", [])

  def aggregate(members) do
    counted =
      for {%Monitor{enabled: true} = monitor, %CheckResult{status: status}} <- members,
          status not in @ignored,
          do: {monitor, status}

    ids = Enum.map(counted, &elem(&1, 0).id)
    {status, message} = summarize(counted)
    {status, details} = result(status, message, ids)

    if status == :warning,
      do: {:up, Map.put(details, :warning, true)},
      else: {status, details}
  end

  # {:up | :down | :warning, message} of the counted members.
  defp summarize([]), do: {:up, "No active members"}

  defp summarize(counted) do
    total = length(counted)
    of_total = fn monitors -> "#{length(monitors)} of #{total} #{members(total)}" end
    failing = for {monitor, status} <- counted, status in @failing, do: monitor
    warning = for {monitor, :warning} <- counted, do: monitor
    pending = for {monitor, :pending} <- counted, do: monitor

    cond do
      failing != [] ->
        {:down, of_total.(failing) <> " down: " <> names(failing)}

      warning != [] ->
        {:warning, of_total.(warning) <> " with a warning: " <> names(warning)}

      pending != [] ->
        {:up,
         "#{total - length(pending)} of #{total} #{members(total)} up, " <>
           "#{length(pending)} retrying: " <> names(pending)}

      total == 1 ->
        {:up, "1 member up"}

      true ->
        {:up, "All #{total} members up"}
    end
  end

  defp result(status, message, ids),
    do: {status, %{response_time_ms: nil, message: message, meta: %{members: ids}}}

  defp members(1), do: "member"
  defp members(_count), do: "members"

  defp names(monitors) do
    {shown, rest} = Enum.split(monitors, @max_names)
    names = Enum.map_join(shown, ", ", & &1.name)
    if rest == [], do: names, else: "#{names} and #{length(rest)} more"
  end
end
