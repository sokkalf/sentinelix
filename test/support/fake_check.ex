defmodule Sentinelix.FakeCheck do
  @moduledoc """
  A scriptable `Sentinelix.Checks.Check` for engine tests.

  Start it with `start_supervised!(Sentinelix.FakeCheck)` and queue results
  per monitor with `push/2`. Each run pops the next queued result; with an
  empty queue the check is up. Besides `{status, details}` tuples a queued
  result can be:

    * `:hang` – never returns (to test timeouts),
    * `:hang_trapping_exits` – traps exits and never returns,
    * `:raise` – raises,
    * any other term – returned as is (to test invalid results).
  """

  @behaviour Sentinelix.Checks.Check

  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Queues results for a monitor."
  def push(monitor, results) when is_list(results) do
    Agent.update(
      __MODULE__,
      &Map.update(&1, monitor.id, results, fn queue -> queue ++ results end)
    )
  end

  @impl true
  def run(monitor) do
    next =
      Agent.get_and_update(__MODULE__, fn queues ->
        case Map.get(queues, monitor.id, []) do
          [next | rest] -> {next, Map.put(queues, monitor.id, rest)}
          [] -> {{:up, %{message: "ok"}}, queues}
        end
      end)

    case next do
      :hang -> Process.sleep(:infinity)
      :hang_trapping_exits -> hang_trapping_exits()
      :raise -> raise "boom"
      result -> result
    end
  end

  defp hang_trapping_exits do
    Process.flag(:trap_exit, true)
    Process.sleep(:infinity)
  end
end
