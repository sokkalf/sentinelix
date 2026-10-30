defmodule Sentinelix.MaintenanceFixtures do
  @moduledoc """
  Test helpers for creating maintenance windows via the
  `Sentinelix.Maintenance` context.

  Windows are cached globally (`Sentinelix.Maintenance.Cache`): tests using
  them must not be async and should call `reset_maintenance_cache/1` in
  their setup.
  """

  alias Sentinelix.Maintenance
  alias Sentinelix.Maintenance.Cache

  @doc """
  A one-off window active right now (from an hour ago for two hours), for
  the given monitors (or all monitors with `all_monitors: true`).
  """
  def window_fixture(attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, window} =
      attrs
      |> Enum.into(%{
        title: "Maintenance #{System.unique_integer([:positive])}",
        starts_at: DateTime.add(now, -1, :hour),
        ends_at: DateTime.add(now, 1, :hour)
      })
      |> Maintenance.create_window()

    window
  end

  @doc """
  Clears the maintenance window cache now and after the test.
  """
  def reset_maintenance_cache(_context \\ %{}) do
    Cache.reset()
    ExUnit.Callbacks.on_exit(&Cache.reset/0)
    :ok
  end
end
