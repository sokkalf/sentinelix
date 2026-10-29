defmodule Sentinelix.Metrics.CheckMeta do
  @moduledoc """
  Remembers check metadata that is not persisted with check results but is
  exported as a metric – currently the `days_remaining` of certificate
  checks (`meta.days_remaining`).

  A `[:sentinelix, :check, :stop]` telemetry handler writes into a public
  ETS table owned by this process. A check without `days_remaining` in its
  meta (e.g. one that could not fetch the certificate) removes the entry, so
  a stale value is never reported.
  """

  use GenServer

  @table __MODULE__
  @handler_id {__MODULE__, :check_stop}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The last reported certificate days remaining per monitor id.
  """
  @spec days_remaining() :: %{pos_integer() => integer()}
  def days_remaining do
    Map.new(:ets.tab2list(@table))
  rescue
    ArgumentError -> %{}
  end

  @doc """
  Removes the entries of monitors that are not in `monitor_ids` (deleted
  monitors).
  """
  @spec prune([pos_integer()]) :: :ok
  def prune(monitor_ids) do
    keep = MapSet.new(monitor_ids)

    for {id, _days} <- :ets.tab2list(@table), not MapSet.member?(keep, id) do
      :ets.delete(@table, id)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def handle_event([:sentinelix, :check, :stop], _measurements, metadata, _config) do
    case metadata do
      %{monitor_id: id, meta: %{days_remaining: days}} when is_integer(days) ->
        :ets.insert(@table, {id, days})

      %{monitor_id: id} ->
        :ets.delete(@table, id)
    end
  rescue
    # The table is gone (this process is restarting); drop the event.
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    # A handler left behind by a previous incarnation of this process would
    # make attach/4 fail.
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach(
        @handler_id,
        [:sentinelix, :check, :stop],
        &__MODULE__.handle_event/4,
        nil
      )

    {:ok, nil}
  end
end
