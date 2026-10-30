defmodule Sentinelix.RateLimit do
  @moduledoc """
  Fixed-window rate limiting (Hammer, ETS backend) for the endpoints that
  are reachable without a session: the local login form and the push
  endpoint.

  Limits are configured per bucket as `{limit, period_ms}`; `nil` (or a
  limit of 0) disables the bucket:

      config :sentinelix, Sentinelix.RateLimit,
        login: {10, 60_000},
        push: {300, 60_000}

  In production `LOGIN_RATE_LIMIT` and `PUSH_RATE_LIMIT` set the limit per
  minute (see config/runtime.exs). The key is usually the client IP, see
  `SentinelixWeb.Plugs.ClientIP` for running behind a reverse proxy.
  """

  use Hammer, backend: :ets

  @type bucket :: :login | :push

  @doc """
  Counts a request of `key` in `bucket`.

  Returns `:ok` while the bucket's limit isn't exceeded (or the bucket has no
  limit), otherwise `{:error, retry_after_ms}`.
  """
  @spec check(bucket(), term()) :: :ok | {:error, non_neg_integer()}
  def check(bucket, key) do
    case limit(bucket) do
      {limit, period_ms} when is_integer(limit) and limit > 0 ->
        case hit({bucket, key}, period_ms, limit) do
          {:allow, _count} -> :ok
          {:deny, retry_after_ms} -> {:error, retry_after_ms}
        end

      _disabled ->
        :ok
    end
  end

  defp limit(bucket) do
    Application.get_env(:sentinelix, __MODULE__, []) |> Keyword.get(bucket)
  end
end
