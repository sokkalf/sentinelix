defmodule Sentinelix.Maintenance.WindowTest do
  use ExUnit.Case, async: true

  import Sentinelix.DataCase, only: [errors_on: 1]

  alias Sentinelix.Maintenance.Window

  defp once(starts_at, ends_at, attrs \\ %{}) do
    struct!(
      Window,
      Map.merge(%{recurrence: :once, starts_at: starts_at, ends_at: ends_at}, attrs)
    )
  end

  defp recurring(recurrence, start_time, minutes, attrs \\ %{}) do
    struct!(
      Window,
      Map.merge(
        %{
          recurrence: recurrence,
          start_time: start_time,
          duration_minutes: minutes,
          timezone: "Etc/UTC"
        },
        attrs
      )
    )
  end

  describe "one-off windows" do
    test "are active from start (inclusive) to end (exclusive)" do
      window = once(~U[2026-11-01 22:00:00Z], ~U[2026-11-01 23:00:00Z])

      refute Window.active?(window, ~U[2026-11-01 21:59:59Z])
      assert Window.active?(window, ~U[2026-11-01 22:00:00Z])
      assert Window.active?(window, ~U[2026-11-01 22:59:59Z])
      refute Window.active?(window, ~U[2026-11-01 23:00:00Z])

      assert Window.current_occurrence(window, ~U[2026-11-01 22:30:00Z]) ==
               {~U[2026-11-01 22:00:00Z], ~U[2026-11-01 23:00:00Z]}
    end

    test "are never active when disabled" do
      window = once(~U[2026-11-01 22:00:00Z], ~U[2026-11-01 23:00:00Z], %{enabled: false})
      refute Window.active?(window, ~U[2026-11-01 22:30:00Z])
      assert Window.status(window, ~U[2026-11-01 22:30:00Z]) == :disabled
    end

    test "status and next occurrence" do
      window = once(~U[2026-11-01 22:00:00Z], ~U[2026-11-01 23:00:00Z])
      occurrence = {~U[2026-11-01 22:00:00Z], ~U[2026-11-01 23:00:00Z]}

      assert Window.status(window, ~U[2026-11-01 12:00:00Z]) == :scheduled
      assert Window.next_occurrence(window, ~U[2026-11-01 12:00:00Z]) == occurrence
      assert Window.status(window, ~U[2026-11-01 22:10:00Z]) == :active
      assert Window.next_occurrence(window, ~U[2026-11-01 22:10:00Z]) == occurrence
      assert Window.status(window, ~U[2026-11-02 00:00:00Z]) == :ended
      assert Window.next_occurrence(window, ~U[2026-11-02 00:00:00Z]) == nil
    end
  end

  describe "daily windows" do
    test "are active every day at the start time for the duration" do
      window = recurring(:daily, ~T[02:00:00], 90)

      refute Window.active?(window, ~U[2026-11-03 01:59:00Z])
      assert Window.active?(window, ~U[2026-11-03 02:00:00Z])
      assert Window.active?(window, ~U[2026-11-03 03:29:59Z])
      refute Window.active?(window, ~U[2026-11-03 03:30:00Z])
      assert Window.active?(window, ~U[2026-11-04 02:45:00Z])
    end

    test "can span midnight" do
      window = recurring(:daily, ~T[23:00:00], 120)

      assert Window.active?(window, ~U[2026-11-03 23:30:00Z])
      assert Window.active?(window, ~U[2026-11-04 00:59:00Z])
      refute Window.active?(window, ~U[2026-11-04 01:00:00Z])

      assert Window.current_occurrence(window, ~U[2026-11-04 00:30:00Z]) ==
               {~U[2026-11-03 23:00:00Z], ~U[2026-11-04 01:00:00Z]}
    end

    test "next occurrence" do
      window = recurring(:daily, ~T[02:00:00], 60)

      assert Window.next_occurrence(window, ~U[2026-11-03 12:00:00Z]) ==
               {~U[2026-11-04 02:00:00Z], ~U[2026-11-04 03:00:00Z]}

      assert Window.status(window, ~U[2026-11-03 12:00:00Z]) == :scheduled
    end

    test "respect the effective from/until bounds" do
      window =
        recurring(:daily, ~T[02:00:00], 60, %{
          starts_at: ~U[2026-11-05 00:00:00Z],
          ends_at: ~U[2026-11-07 02:30:00Z]
        })

      refute Window.active?(window, ~U[2026-11-04 02:30:00Z])
      assert Window.active?(window, ~U[2026-11-05 02:30:00Z])
      assert Window.active?(window, ~U[2026-11-07 02:15:00Z])
      # Clipped to the end of the bounds.
      refute Window.active?(window, ~U[2026-11-07 02:45:00Z])

      assert Window.current_occurrence(window, ~U[2026-11-07 02:15:00Z]) ==
               {~U[2026-11-07 02:00:00Z], ~U[2026-11-07 02:30:00Z]}

      assert Window.next_occurrence(window, ~U[2026-10-01 00:00:00Z]) ==
               {~U[2026-11-05 02:00:00Z], ~U[2026-11-05 03:00:00Z]}

      assert Window.status(window, ~U[2026-11-08 00:00:00Z]) == :ended
    end
  end

  describe "weekly windows" do
    # 2026-11-02 is a Monday.
    test "are active on the selected weekdays only" do
      window = recurring(:weekly, ~T[22:00:00], 60, %{weekdays: [1, 3]})

      assert Window.active?(window, ~U[2026-11-02 22:30:00Z])
      refute Window.active?(window, ~U[2026-11-03 22:30:00Z])
      assert Window.active?(window, ~U[2026-11-04 22:30:00Z])
      refute Window.active?(window, ~U[2026-11-05 22:30:00Z])
      assert Window.active?(window, ~U[2026-11-09 22:30:00Z])
    end

    test "can last several days" do
      # Saturday 20:00 until Monday 06:00.
      window = recurring(:weekly, ~T[20:00:00], 34 * 60, %{weekdays: [6]})

      refute Window.active?(window, ~U[2026-11-07 19:59:00Z])
      assert Window.active?(window, ~U[2026-11-07 20:00:00Z])
      assert Window.active?(window, ~U[2026-11-08 12:00:00Z])
      assert Window.active?(window, ~U[2026-11-09 05:59:00Z])
      refute Window.active?(window, ~U[2026-11-09 06:00:00Z])
    end

    test "next occurrence skips other weekdays" do
      window = recurring(:weekly, ~T[22:00:00], 60, %{weekdays: [5]})

      assert Window.next_occurrence(window, ~U[2026-11-02 12:00:00Z]) ==
               {~U[2026-11-06 22:00:00Z], ~U[2026-11-06 23:00:00Z]}
    end
  end

  describe "time zones" do
    test "the start time is local to the window's time zone" do
      window = recurring(:daily, ~T[02:00:00], 60, %{timezone: "Europe/Oslo"})

      # Winter (CET, UTC+1): 02:00 local is 01:00 UTC.
      assert Window.active?(window, ~U[2026-01-15 01:30:00Z])
      refute Window.active?(window, ~U[2026-01-15 02:30:00Z])
      # Summer (CEST, UTC+2): 02:00 local is 00:00 UTC.
      assert Window.active?(window, ~U[2026-07-15 00:30:00Z])
      refute Window.active?(window, ~U[2026-07-15 01:30:00Z])
    end

    test "weekdays are local to the window's time zone" do
      # Monday 01:00 in Tokyo is Sunday 16:00 UTC.
      window = recurring(:weekly, ~T[01:00:00], 60, %{weekdays: [1], timezone: "Asia/Tokyo"})

      assert Window.active?(window, ~U[2026-11-01 16:30:00Z])
      refute Window.active?(window, ~U[2026-11-02 16:30:00Z])
    end

    test "a start time in the DST gap starts at the end of the gap" do
      # Clocks jump from 02:00 to 03:00 on 2026-03-29 in Oslo.
      window = recurring(:daily, ~T[02:30:00], 60, %{timezone: "Europe/Oslo"})

      assert Window.current_occurrence(window, ~U[2026-03-29 01:30:00Z]) ==
               {~U[2026-03-29 01:00:00Z], ~U[2026-03-29 02:00:00Z]}
    end

    test "an ambiguous start time uses the first occurrence and the real duration" do
      # Clocks go back from 03:00 to 02:00 on 2026-10-25 in Oslo.
      window = recurring(:daily, ~T[02:30:00], 60, %{timezone: "Europe/Oslo"})

      assert Window.current_occurrence(window, ~U[2026-10-25 00:45:00Z]) ==
               {~U[2026-10-25 00:30:00Z], ~U[2026-10-25 01:30:00Z]}

      refute Window.active?(window, ~U[2026-10-25 01:45:00Z])
    end

    test "the occurrence across a DST change lasts the configured duration" do
      # 01:00 local + 3h on the night clocks go forward ends at 05:00 local.
      window = recurring(:daily, ~T[01:00:00], 180, %{timezone: "Europe/Oslo"})

      assert Window.current_occurrence(window, ~U[2026-03-29 01:00:00Z]) ==
               {~U[2026-03-29 00:00:00Z], ~U[2026-03-29 03:00:00Z]}
    end
  end

  describe "applies_to?/2" do
    test "all monitors or the attached ones" do
      assert Window.applies_to?(%Window{all_monitors: true}, 1)
      assert Window.applies_to?(%Window{monitor_ids: [1, 2]}, 2)
      refute Window.applies_to?(%Window{monitor_ids: [1, 2]}, 3)
    end
  end

  describe "changeset/3" do
    test "one-off windows need a start before the end" do
      changeset =
        Window.changeset(
          %Window{},
          %{title: "x", all_monitors: true, starts_at: ~U[2026-11-01 22:00:00Z]}
        )

      assert "can't be blank" in errors_on(changeset).ends_at

      changeset =
        Window.changeset(%Window{}, %{
          title: "x",
          all_monitors: true,
          starts_at: ~U[2026-11-01 22:00:00Z],
          ends_at: ~U[2026-11-01 21:00:00Z]
        })

      assert "must be after the start" in errors_on(changeset).ends_at
    end

    test "local times are converted from the window's time zone" do
      changeset =
        Window.changeset(%Window{}, %{
          "title" => "Upgrade",
          "all_monitors" => "true",
          "timezone" => "Europe/Oslo",
          "local_starts_at" => "2026-11-01T22:00",
          "local_ends_at" => "2026-11-01T23:30"
        })

      assert changeset.valid?
      assert get_change(changeset, :starts_at) == ~U[2026-11-01 21:00:00Z]
      assert get_change(changeset, :ends_at) == ~U[2026-11-01 22:30:00Z]

      window = Window.put_local_times(Ecto.Changeset.apply_changes(changeset))
      assert window.local_starts_at == ~N[2026-11-01 22:00:00]
      assert window.local_ends_at == ~N[2026-11-01 23:30:00]
    end

    test "validates the time zone" do
      changeset =
        Window.changeset(%Window{}, %{
          title: "x",
          all_monitors: true,
          timezone: "Mars/Olympus",
          recurrence: :daily,
          start_time: ~T[02:00:00],
          duration_minutes: 30
        })

      assert "is not a known time zone" in errors_on(changeset).timezone
    end

    test "validates recurring schedules" do
      base = %{title: "x", all_monitors: true, start_time: ~T[02:00:00]}

      changeset =
        Window.changeset(
          %Window{},
          Map.merge(base, %{recurrence: :daily, duration_minutes: 1441})
        )

      assert errors_on(changeset).duration_minutes != []

      changeset =
        Window.changeset(
          %Window{},
          Map.merge(base, %{recurrence: :weekly, duration_minutes: 60, weekdays: []})
        )

      assert "select at least one day" in errors_on(changeset).weekdays

      changeset =
        Window.changeset(
          %Window{},
          Map.merge(base, %{recurrence: :weekly, duration_minutes: 60, weekdays: [3, 1, 3, 8]})
        )

      assert errors_on(changeset).weekdays != []

      changeset =
        Window.changeset(
          %Window{},
          Map.merge(base, %{recurrence: :weekly, duration_minutes: 60, weekdays: [3, 1, 3]})
        )

      assert changeset.valid?
      assert get_change(changeset, :weekdays) == [1, 3]
    end

    test "needs monitors unless it applies to all monitors" do
      attrs = %{
        title: "x",
        starts_at: ~U[2026-11-01 22:00:00Z],
        ends_at: ~U[2026-11-01 23:00:00Z]
      }

      changeset = Window.changeset(%Window{monitors: []}, attrs, [])
      assert "select at least one monitor or all monitors" in errors_on(changeset).monitors

      assert Window.changeset(%Window{monitors: []}, Map.put(attrs, :all_monitors, true), []).valid?
    end
  end

  defp get_change(changeset, field), do: Ecto.Changeset.get_change(changeset, field)
end
