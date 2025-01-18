defmodule Sentinelix.Monitor do
  @moduledoc """
  Behaviour definition for all Sentinelix monitors.
  """

  @doc """
  Start the monitor GenServer. Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Return the current status of the monitor.
  """
  @callback status(pid :: pid()) :: any()

end
