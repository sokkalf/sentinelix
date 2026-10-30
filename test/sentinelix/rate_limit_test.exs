defmodule Sentinelix.RateLimitTest do
  use ExUnit.Case, async: true

  alias Sentinelix.RateLimit

  test "allows requests up to the bucket's limit" do
    key = make_ref()
    {limit, _period} = Application.fetch_env!(:sentinelix, RateLimit)[:login]

    for _ <- 1..limit, do: assert(RateLimit.check(:login, key) == :ok)

    assert {:error, retry_after_ms} = RateLimit.check(:login, key)
    assert retry_after_ms in 0..60_000

    # Other keys and buckets are counted separately.
    assert RateLimit.check(:login, make_ref()) == :ok
    assert RateLimit.check(:push, key) == :ok
  end

  test "buckets without a limit are not limited" do
    key = make_ref()
    for _ <- 1..50, do: assert(RateLimit.check(:unconfigured, key) == :ok)
  end
end
