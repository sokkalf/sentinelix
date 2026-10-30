defmodule Sentinelix.RateLimitHelpers do
  @moduledoc """
  Test helpers for `Sentinelix.RateLimit`.

  The limits use fixed windows (`div(now_ms, period)`), so a test that uses
  up a client's budget and then expects to be refused fails if a window
  boundary falls in between: the counter starts over. Call
  `await_rate_limit_window/2` before such a test.
  """

  @doc """
  Makes sure at least `needed_ms` are left in the current window of
  `bucket`, waiting for the next window to begin if not (at most
  `needed_ms`).
  """
  def await_rate_limit_window(bucket, needed_ms \\ 1_000) do
    {_limit, period} = Application.fetch_env!(:sentinelix, Sentinelix.RateLimit)[bucket]
    left = period - rem(System.system_time(:millisecond), period)
    if left < needed_ms, do: Process.sleep(left + 1)
    :ok
  end
end
