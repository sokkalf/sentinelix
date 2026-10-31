defmodule Sentinelix.Stats.HourlyStat do
  @moduledoc """
  Hourly rollup of a monitor's check results (`check_stats_hourly`).

  Written only by `Sentinelix.Stats.Rollup`, which recomputes whole hours
  from the raw `check_results`. Response time fields cover `:up` results
  only; `avg_ms` is `nil` when `response_count` is 0.
  """

  use Ecto.Schema

  alias Sentinelix.Monitoring.Monitor

  @primary_key false
  schema "check_stats_hourly" do
    belongs_to :monitor, Monitor, primary_key: true
    field :hour, :utc_datetime, primary_key: true
    field :up_count, :integer, default: 0
    field :down_count, :integer, default: 0
    field :pending_count, :integer, default: 0
    field :maintenance_count, :integer, default: 0
    field :unreachable_count, :integer, default: 0
    field :response_count, :integer, default: 0
    field :avg_ms, :float
    field :min_ms, :integer
    field :max_ms, :integer
  end

  @type t :: %__MODULE__{}
end
