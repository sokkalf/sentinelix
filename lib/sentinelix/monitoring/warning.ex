defmodule Sentinelix.Monitoring.Warning do
  @moduledoc """
  An active warning of a monitor, raised by a `warning` event and cleared
  by an `ok` event with the same `key` (`""` without a key), from the
  monitor page, or when it expires (`expires_at`, `nil` for never). See
  `Sentinelix.Monitoring.Events`.

  A monitor has at most one warning per key; raising it again replaces
  its title, message and expiry.
  """

  use Ecto.Schema

  alias Sentinelix.Monitoring.Monitor

  schema "monitor_warnings" do
    field :key, :string, default: ""
    field :title, :string
    field :message, :string
    field :raised_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :monitor, Monitor

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Whether the warning has expired at `now`."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false
  def expired?(%__MODULE__{expires_at: at}, now), do: DateTime.compare(at, now) != :gt
end
