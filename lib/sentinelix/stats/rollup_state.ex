defmodule Sentinelix.Stats.RollupState do
  @moduledoc """
  The rollup watermark (`check_stats_rollup_state`, a single row with id 1):
  all check results before `rolled_up_until` are covered by
  `Sentinelix.Stats.HourlyStat` rows.
  """

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "check_stats_rollup_state" do
    field :rolled_up_until, :utc_datetime
  end

  @type t :: %__MODULE__{}
end
