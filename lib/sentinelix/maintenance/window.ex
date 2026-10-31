defmodule Sentinelix.Maintenance.Window do
  @moduledoc """
  A maintenance window: a period during which monitors are in maintenance.

  A window applies to

    * all monitors (including ones created later) with `all_monitors: true`,
    * otherwise to the monitors attached to it **and** the monitors matching
      its `selector` (a label selector, see `Sentinelix.Monitoring.Selector`;
      `""` for none). Either may be empty, not both.

  Membership by selector is dynamic: a monitor created, relabeled or renamed
  later is in the window as soon as it matches, and leaves it when it no
  longer does. Selectors of windows can't have `status` terms (a window
  chosen by status would change the status of its own monitors), see
  `selector_allow/0`.

  Disabled windows are never active.

  ## Schedule

    * `recurrence: :once` – active from `starts_at` (inclusive) until
      `ends_at` (exclusive).
    * `recurrence: :daily` – every day at `start_time` (local time in
      `timezone`) for `duration_minutes` (at most a day).
    * `recurrence: :weekly` – like daily, but only on the ISO `weekdays`
      (1 = Monday .. 7 = Sunday), for at most a week.

  Recurring windows may be bounded by `starts_at` ("effective from") and
  `ends_at` ("effective until"); occurrences are clipped to these bounds.

  The duration is real elapsed time: an occurrence spanning a daylight
  saving time change lasts `duration_minutes`, not until the same wall clock
  time. A `start_time` that falls into a DST gap starts at the end of the
  gap, an ambiguous one (DST ending) at its first occurrence.

  In forms, one-off windows (and the bounds of recurring ones) are entered
  as local times in `timezone` through the virtual `local_starts_at` and
  `local_ends_at` fields (see `put_local_times/1`); `starts_at` and
  `ends_at` are stored in UTC.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.Monitoring.{Monitor, Selector}

  @recurrences [:once, :daily, :weekly]
  @selector_allow [:labels, :name]
  @max_minutes %{daily: 24 * 60, weekly: 7 * 24 * 60}

  schema "maintenance_windows" do
    field :title, :string
    field :description, :string
    field :enabled, :boolean, default: true
    field :all_monitors, :boolean, default: false
    field :selector, :string, default: ""
    field :timezone, :string, default: "Etc/UTC"
    field :recurrence, Ecto.Enum, values: @recurrences, default: :once
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :start_time, :time
    field :duration_minutes, :integer
    field :weekdays, {:array, :integer}, default: []

    field :local_starts_at, :naive_datetime, virtual: true
    field :local_ends_at, :naive_datetime, virtual: true
    # The ids of the attached monitors, set by Sentinelix.Maintenance when
    # caching windows (so that the cache doesn't hold monitor structs).
    field :monitor_ids, {:array, :integer}, virtual: true, default: []
    # Set by Sentinelix.Maintenance when caching windows: the parsed selector
    # (nil without one) and the ids of the monitors it matched then.
    field :parsed_selector, :any, virtual: true
    field :selector_ids, {:array, :integer}, virtual: true, default: []

    many_to_many :monitors, Monitor,
      join_through: "maintenance_window_monitors",
      join_keys: [maintenance_window_id: :id, monitor_id: :id],
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
  @type recurrence :: :once | :daily | :weekly
  @type occurrence :: {DateTime.t(), DateTime.t()}

  @doc "All recurrence values."
  def recurrences, do: @recurrences

  @doc """
  The kinds of selector terms windows allow (the `:allow` option of
  `Sentinelix.Monitoring.Selector.parse/2`): labels and names, no status.
  """
  @spec selector_allow() :: [Selector.kind()]
  def selector_allow, do: @selector_allow

  @doc """
  Changeset for creating and updating windows. `monitors`, if given,
  replaces the attached monitors.
  """
  def changeset(window, attrs, monitors \\ nil) do
    window
    |> cast(attrs, [
      :title,
      :description,
      :enabled,
      :all_monitors,
      :selector,
      :timezone,
      :recurrence,
      :starts_at,
      :ends_at,
      :local_starts_at,
      :local_ends_at,
      :start_time,
      :duration_minutes,
      :weekdays
    ])
    |> update_change(:title, &(&1 && String.trim(&1)))
    |> validate_required([:title, :timezone, :recurrence])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    # A blank selector is cast to nil; the column stores "" for none.
    |> update_change(:selector, &(&1 || ""))
    |> Selector.validate_selector(:selector, allow: @selector_allow)
    |> validate_timezone()
    |> put_utc_times()
    |> validate_schedule()
    |> put_monitors(monitors)
    |> validate_monitors()
  end

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, tz ->
      if valid_timezone?(tz), do: [], else: [timezone: "is not a known time zone"]
    end)
  end

  @doc "Whether `tz` is a time zone name known to the time zone database."
  @spec valid_timezone?(String.t()) :: boolean()
  def valid_timezone?(tz) when is_binary(tz) do
    match?({:ok, _}, DateTime.now(tz))
  rescue
    _ -> false
  end

  def valid_timezone?(_tz), do: false

  # Local times entered in a form win over UTC times.
  defp put_utc_times(changeset) do
    tz = get_field(changeset, :timezone)

    if valid_timezone?(tz) do
      changeset
      |> put_utc_time(:local_starts_at, :starts_at, tz)
      |> put_utc_time(:local_ends_at, :ends_at, tz)
    else
      changeset
    end
  end

  defp put_utc_time(changeset, local_field, field, tz) do
    if Map.has_key?(changeset.params || %{}, Atom.to_string(local_field)) or
         Map.has_key?(changeset.changes, local_field) do
      case get_field(changeset, local_field) do
        nil -> put_change(changeset, field, nil)
        naive -> put_change(changeset, field, naive |> to_datetime(tz) |> to_utc())
      end
    else
      changeset
    end
  end

  defp validate_schedule(changeset) do
    case get_field(changeset, :recurrence) do
      :once ->
        changeset
        |> validate_required([:starts_at, :ends_at])
        |> copy_errors(starts_at: :local_starts_at, ends_at: :local_ends_at)
        |> validate_order()

      recurrence when recurrence in [:daily, :weekly] ->
        changeset
        |> validate_required([:start_time, :duration_minutes])
        |> validate_number(:duration_minutes,
          greater_than: 0,
          less_than_or_equal_to: @max_minutes[recurrence]
        )
        |> validate_weekdays(recurrence)
        |> validate_order()

      _ ->
        changeset
    end
  end

  defp validate_weekdays(changeset, :daily), do: put_change(changeset, :weekdays, [])

  defp validate_weekdays(changeset, :weekly) do
    changeset
    |> update_change(:weekdays, &(&1 |> Enum.uniq() |> Enum.sort()))
    |> validate_subset(:weekdays, 1..7)
    |> then(fn changeset ->
      if get_field(changeset, :weekdays) in [nil, []],
        do: add_error(changeset, :weekdays, "select at least one day"),
        else: changeset
    end)
  end

  defp validate_order(changeset) do
    starts_at = get_field(changeset, :starts_at)
    ends_at = get_field(changeset, :ends_at)

    if starts_at && ends_at && DateTime.compare(ends_at, starts_at) != :gt do
      changeset
      |> add_error(:ends_at, "must be after the start")
      |> add_error(:local_ends_at, "must be after the start")
    else
      changeset
    end
  end

  defp copy_errors(changeset, mapping) do
    errors =
      for {from, to} <- mapping,
          {msg, opts} <- Keyword.get_values(changeset.errors, from),
          do: {to, msg, opts}

    Enum.reduce(errors, changeset, fn {field, msg, opts}, changeset ->
      add_error(changeset, field, msg, opts)
    end)
  end

  defp put_monitors(changeset, nil), do: changeset
  defp put_monitors(changeset, monitors), do: put_assoc(changeset, :monitors, monitors)

  defp validate_monitors(changeset) do
    monitors = get_field(changeset, :monitors)

    if get_field(changeset, :all_monitors) or not is_list(monitors) or monitors != [] or
         (get_field(changeset, :selector) || "") != "" do
      changeset
    else
      add_error(changeset, :monitors, "select monitors, a selector or all monitors")
    end
  end

  @doc """
  Fills the virtual `local_starts_at` and `local_ends_at` fields from the
  UTC times, for editing in a form.
  """
  @spec put_local_times(t()) :: t()
  def put_local_times(%__MODULE__{} = window) do
    %{
      window
      | local_starts_at: to_local(window.starts_at, window.timezone),
        local_ends_at: to_local(window.ends_at, window.timezone)
    }
  end

  defp to_local(nil, _tz), do: nil

  defp to_local(%DateTime{} = at, tz) do
    case DateTime.shift_zone(at, tz) do
      {:ok, local} -> DateTime.to_naive(local)
      _ -> DateTime.to_naive(at)
    end
  end

  ## Schedule calculation

  @doc """
  Whether the window applies to a monitor: all monitors, an attached
  monitor (`monitor_ids`) or one matching the selector.

  Given a monitor struct, the selector is evaluated on it in memory
  (`Sentinelix.Monitoring.Selector.matches?/3` on its labels and name), so
  the answer is current even for a monitor created or changed a moment ago.
  Given an id, the window's `selector_ids` are used, the matches computed
  when the window was cached (`Sentinelix.Maintenance.Cache` recomputes
  them when monitors change).
  """
  @spec applies_to?(t(), Monitor.t() | pos_integer()) :: boolean()
  def applies_to?(%__MODULE__{all_monitors: true}, _monitor), do: true

  def applies_to?(%__MODULE__{monitor_ids: ids} = window, %Monitor{id: id} = monitor),
    do: id in ids or selects?(window, monitor)

  def applies_to?(%__MODULE__{monitor_ids: ids, selector_ids: selector_ids}, monitor_id)
      when is_integer(monitor_id),
      do: monitor_id in ids or monitor_id in selector_ids

  defp selects?(window, monitor) do
    case parsed_selector(window) do
      nil -> false
      selector -> Selector.matches?(selector, monitor)
    end
  end

  @doc """
  The window's selector, parsed, or `nil` if it has none (or, in case a
  stored one became invalid, an invalid one). Uses `parsed_selector` when
  the window was loaded for the cache.
  """
  @spec parsed_selector(t()) :: Selector.t() | nil
  def parsed_selector(%__MODULE__{parsed_selector: %Selector{} = selector}), do: selector
  def parsed_selector(%__MODULE__{selector: text}) when text in [nil, ""], do: nil

  def parsed_selector(%__MODULE__{selector: text}) do
    case Selector.parse(text, allow: @selector_allow) do
      {:ok, selector} -> if Selector.empty?(selector), do: nil, else: selector
      {:error, _error} -> nil
    end
  end

  @doc """
  Whether the window is active at `now`.
  """
  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(window, now), do: current_occurrence(window, now) != nil

  @doc """
  The occurrence `{starts_at, ends_at}` (UTC) of the window that is active
  at `now`, or `nil`.
  """
  @spec current_occurrence(t(), DateTime.t()) :: occurrence() | nil
  def current_occurrence(%__MODULE__{enabled: false}, _now), do: nil

  def current_occurrence(%__MODULE__{recurrence: :once, starts_at: s, ends_at: e}, now) do
    if s && e && covers?({s, e}, now), do: {s, e}
  end

  def current_occurrence(%__MODULE__{} = window, now) do
    if in_bounds?(window, now) do
      window
      |> candidates(now, -lookback_days(window), 0)
      |> Enum.find(&covers?(&1, now))
      |> clip(window)
    end
  end

  @doc """
  The occurrence `{starts_at, ends_at}` (UTC) of the window that is active
  at `now` or, if none is, the next one. `nil` if there is none (disabled,
  ended).
  """
  @spec next_occurrence(t(), DateTime.t()) :: occurrence() | nil
  def next_occurrence(%__MODULE__{enabled: false}, _now), do: nil

  def next_occurrence(%__MODULE__{recurrence: :once, starts_at: s, ends_at: e}, now) do
    if s && e && DateTime.compare(e, now) == :gt, do: {s, e}
  end

  def next_occurrence(%__MODULE__{} = window, now) do
    from = later(now, window.starts_at)

    if window.ends_at && DateTime.compare(from, window.ends_at) != :lt do
      nil
    else
      window
      |> candidates(from, -lookback_days(window), 8)
      |> Enum.map(&clip(&1, window))
      |> Enum.find(fn {s, e} ->
        DateTime.compare(e, now) == :gt and DateTime.compare(s, e) == :lt
      end)
    end
  end

  @doc """
  The window's state at `now`: `:disabled`, `:active`, `:scheduled` (a later
  occurrence exists) or `:ended`.
  """
  @spec status(t(), DateTime.t()) :: :disabled | :active | :scheduled | :ended
  def status(%__MODULE__{enabled: false}, _now), do: :disabled

  def status(window, now) do
    cond do
      active?(window, now) -> :active
      next_occurrence(window, now) -> :scheduled
      true -> :ended
    end
  end

  # Occurrences starting on the local dates `from_offset..to_offset` days
  # around `at`, in chronological order.
  defp candidates(window, at, from_offset, to_offset) do
    date = at |> DateTime.shift_zone!(window.timezone) |> DateTime.to_date()

    for offset <- from_offset..to_offset,
        day = Date.add(date, offset),
        runs_on?(window, day) do
      starts_at = day |> NaiveDateTime.new!(window.start_time) |> to_datetime(window.timezone)
      {to_utc(starts_at), starts_at |> DateTime.add(window.duration_minutes, :minute) |> to_utc()}
    end
  end

  # Occurrences starting this many days before today can still be active.
  defp lookback_days(window), do: div(window.duration_minutes, 24 * 60) + 1

  defp runs_on?(%{recurrence: :daily}, _day), do: true
  defp runs_on?(%{recurrence: :weekly, weekdays: days}, day), do: Date.day_of_week(day) in days

  defp in_bounds?(window, now) do
    (window.starts_at == nil or DateTime.compare(now, window.starts_at) != :lt) and
      (window.ends_at == nil or DateTime.compare(now, window.ends_at) == :lt)
  end

  defp clip(nil, _window), do: nil

  defp clip({s, e}, window) do
    {later(s, window.starts_at), earlier(e, window.ends_at)}
  end

  defp covers?({s, e}, now),
    do: DateTime.compare(now, s) != :lt and DateTime.compare(now, e) == :lt

  defp later(a, nil), do: a
  defp later(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp earlier(a, nil), do: a
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  # A local time in `tz`; gaps resolve to their end, ambiguous times to the
  # first occurrence.
  defp to_datetime(%NaiveDateTime{} = naive, tz) do
    case DateTime.from_naive(naive, tz) do
      {:ok, datetime} -> datetime
      {:ambiguous, first, _second} -> first
      {:gap, _before, after_gap} -> after_gap
    end
  end

  defp to_utc(%DateTime{} = datetime) do
    datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end
end
