defmodule Sentinelix.Monitoring.Grouping do
  @moduledoc """
  Groups monitors by label keys and summarizes each group: how many are
  in each status, the worst status and the uptime. Pure functions on
  entries the caller already has (the dashboard's index), so groups can be
  recomputed on every status change.

  ## Entries

  An entry is a map with at least:

    * `:monitor` – the monitor; its labels are read from `all_labels`
      (user and automatic labels, see `Sentinelix.Monitoring.Selector`),
      or `labels` and `auto_labels` for a monitor not saved yet.
    * `:status` – its status as the dashboard shows it (see `statuses/0`).
    * `:checks` (optional) – its check result counts over the uptime
      window (`%{up: n, down: n, unreachable: n}`, e.g. from
      `Sentinelix.Stats.summaries/3`), for the group's uptime. Entries
      without count as no data.

  ## Groups

  `group/3` groups by one key, or by more for nesting (`["service",
  "site"]`: a group per service, each with a group per site). Monitors
  without the key go to a group with `value: nil` ("(none)"). Each monitor
  is in exactly one group per level. Grouping by no keys gives one group
  (`key: nil`) with all entries, so a flat list is the same shape.

  Groups are identified by their `id`, the path of `key=value` from the
  top (`"service=api,site=oslo"`; `"!site"` for "(none)", `"legacy="` for a
  label without a value). Ids are stable across regrouping by the same
  keys, so state such as "collapsed" can be kept per id.

  ## Statuses

  `severity/0` orders the statuses from worst to best. A group's worst
  status is the most severe status of its monitors, and a group has
  `problems` when one of them is down, unreachable or pending
  (`problem_statuses/0`).
  Statuses unknown to this module rank as the most severe, so a new status
  shows rather than hides; add it to `severity/0`.
  """

  alias Sentinelix.Monitoring.Labels
  alias Sentinelix.Stats

  @severity [:down, :unreachable, :pending, :maintenance, :up, :paused]
  @problem_statuses [:down, :unreachable, :pending]
  @sorts [:problems, :name]

  defmodule Group do
    @moduledoc """
    A group of monitors (see `Sentinelix.Monitoring.Grouping`).

      * `id` – the path from the top, see "Groups" in the module docs.
      * `key`, `value` – the label of this level (`value: nil` for monitors
        without the key, `key: nil` for the single group of no grouping).
      * `counts` – monitors per status (every status of
        `Sentinelix.Monitoring.Grouping.severity/0`, 0 when none), `total`.
      * `worst` – the most severe status present, `nil` when empty.
      * `problems` – whether a monitor is down, unreachable or pending.
      * `uptime` – the uptime percentage over all checks of its monitors
        (see `Sentinelix.Stats.uptime_percent/1`), `nil` without checks.
      * `groups` – the nested groups (one level per further key), `[]` at
        the last level.
      * `entries` – the entries of the group and its nested groups, sorted
        by name.
    """

    @enforce_keys [:id, :key, :value]
    defstruct [
      :id,
      :key,
      :value,
      :worst,
      :uptime,
      counts: %{},
      total: 0,
      problems: false,
      groups: [],
      entries: []
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            key: Labels.key() | nil,
            value: Labels.value() | nil,
            counts: %{atom() => non_neg_integer()},
            total: non_neg_integer(),
            worst: atom() | nil,
            problems: boolean(),
            uptime: float() | nil,
            groups: [t()],
            entries: [map()]
          }
  end

  @type entry :: %{
          required(:monitor) => map(),
          required(:status) => atom(),
          optional(:checks) => %{atom() => non_neg_integer()} | nil,
          optional(atom()) => term()
        }

  @type sort :: :problems | :name

  @doc "The statuses from worst to best."
  @spec severity() :: [atom()]
  def severity, do: @severity

  @doc "The statuses that make a group a problem: down, unreachable and pending."
  @spec problem_statuses() :: [atom()]
  def problem_statuses, do: @problem_statuses

  @doc """
  The orders of groups (`sort_groups/2`): `:problems` (default) and `:name`.
  """
  @spec sorts() :: [sort()]
  def sorts, do: @sorts

  @doc """
  Groups entries by `keys` (outermost first), see the module docs. Empty
  without entries.

  ## Options

    * `:sort` – the order of the groups at each level, see
      `sort_groups/2` (default `:problems`).
  """
  @spec group([entry()], [Labels.key()], keyword()) :: [Group.t()]
  def group(entries, keys, opts \\ [])
  def group([], _keys, _opts), do: []

  def group(entries, [], _opts) do
    [summarize(%Group{id: "", key: nil, value: nil}, sort_entries(entries))]
  end

  def group(entries, keys, opts) do
    sort = Keyword.get(opts, :sort, :problems)
    entries |> sort_entries() |> build_level(keys, nil, sort)
  end

  # Entries arrive sorted, and `group_by` keeps their order.
  defp build_level(entries, [key | keys], parent_id, sort) do
    entries
    |> Enum.group_by(&Map.get(labels_of(&1.monitor), key))
    |> Enum.map(fn {value, entries} ->
      id = join_id(parent_id, segment(key, value))
      group = summarize(%Group{id: id, key: key, value: value}, entries)

      case keys do
        [] -> group
        keys -> %{group | groups: build_level(entries, keys, id, sort)}
      end
    end)
    |> sort_groups(sort)
  end

  defp segment(key, nil), do: "!" <> key
  defp segment(key, value), do: key <> "=" <> value

  defp join_id(nil, segment), do: segment
  defp join_id(parent, segment), do: parent <> "," <> segment

  defp labels_of(%{all_labels: labels}) when is_map(labels), do: labels

  defp labels_of(monitor),
    do: Map.merge(Map.get(monitor, :labels) || %{}, Map.get(monitor, :auto_labels) || %{})

  @doc """
  Sorts entries by monitor name (case-insensitive), then id.
  """
  @spec sort_entries([entry()]) :: [entry()]
  def sort_entries(entries),
    do: Enum.sort_by(entries, &{String.downcase(&1.monitor.name), &1.monitor.id})

  @doc """
  Fills in a group's summary (counts, worst status, problems, uptime) and
  entries.
  """
  @spec summarize(Group.t(), [entry()]) :: Group.t()
  def summarize(%Group{} = group, entries) do
    counts = Map.merge(Map.new(@severity, &{&1, 0}), Enum.frequencies_by(entries, & &1.status))

    %{
      group
      | entries: entries,
        counts: counts,
        total: length(entries),
        worst: worst_status(counts),
        problems: Enum.any?(@problem_statuses, &(counts[&1] > 0)),
        uptime: entries |> Enum.map(&Map.get(&1, :checks)) |> uptime()
    }
  end

  @doc """
  The most severe status with a count above 0, `nil` when there is none.

      iex> Sentinelix.Monitoring.Grouping.worst_status(%{up: 3, pending: 1, down: 0})
      :pending
  """
  @spec worst_status(%{atom() => non_neg_integer()}) :: atom() | nil
  def worst_status(counts) do
    counts
    |> Enum.filter(fn {_status, n} -> n > 0 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.min_by(&rank/1, fn -> nil end)
  end

  @doc """
  The rank of a status in `severity/0`, 0 the worst. Unknown statuses
  rank as the worst (-1).
  """
  @spec rank(atom()) :: integer()
  def rank(status), do: Enum.find_index(@severity, &(&1 == status)) || -1

  @doc """
  The uptime percentage of check result counts (`%{up: n, down: n,
  unreachable: n}`, or a list of them, `nil`s ignored), as
  `Sentinelix.Stats.uptime_percent/1` computes it for one monitor: over
  all checks, so a group of one has its monitor's uptime. `nil` without
  checks.

      iex> Sentinelix.Monitoring.Grouping.uptime([%{up: 3, down: 1}, nil, %{up: 0, down: 0}])
      75.0
  """
  @spec uptime(%{atom() => non_neg_integer()} | [map() | nil] | nil) :: float() | nil
  def uptime(checks) when is_list(checks) do
    checks
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _status, a, b -> a + b end))
    |> Stats.uptime_percent()
  end

  def uptime(nil), do: nil
  def uptime(checks) when is_map(checks), do: Stats.uptime_percent(checks)

  @doc """
  Sorts groups:

    * `:problems` – groups with problems first, the worst status first,
      then the rest; by value within each.
    * `:name` – by value.

  Values sort case-insensitively, the "(none)" group (`value: nil`) last.
  """
  @spec sort_groups([Group.t()], sort()) :: [Group.t()]
  def sort_groups(groups, :name), do: Enum.sort_by(groups, &value_order/1)

  def sort_groups(groups, :problems) do
    Enum.sort_by(groups, fn group ->
      if group.problems,
        do: {0, rank(group.worst), value_order(group)},
        else: {1, 0, value_order(group)}
    end)
  end

  defp value_order(%Group{value: nil}), do: {1, "", ""}
  defp value_order(%Group{value: value}), do: {0, String.downcase(value), value}

  @doc """
  All groups of a tree, outermost first (each group followed by its
  nested groups).
  """
  @spec flatten([Group.t()]) :: [Group.t()]
  def flatten(groups), do: Enum.flat_map(groups, &[&1 | flatten(&1.groups)])
end
