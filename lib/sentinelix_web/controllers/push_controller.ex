defmodule SentinelixWeb.PushController do
  @moduledoc """
  Public push (heartbeat) endpoint for push monitors.

      GET|POST /api/push/:token?status=up|down&msg=...&ping=<ms>

  No authentication: the token identifies (and authorizes) the monitor. The
  lookup is a single indexed query, so the endpoint is cheap enough to be
  hit frequently; requests are rate limited per client IP (`:push` bucket of
  `Sentinelix.RateLimit`, `PUSH_RATE_LIMIT` in production). Parameters can
  also be sent as a form or JSON body with POST. See
  `Sentinelix.Monitoring.receive_push/2`.

  Responses (JSON):

    * `200 {"ok": true, "status": "up"}` – recorded; `status` is the
      monitor's resulting status (`up`, `down`, `pending` or `maintenance`)
    * `400` – invalid `status` parameter
    * `404` – unknown token or the monitor is disabled
    * `429` – rate limit exceeded (with a `retry-after` header)
    * `503` – the monitoring engine isn't running the monitor
  """

  use SentinelixWeb, :controller

  alias Sentinelix.{Monitoring, RateLimit}

  def push(conn, %{"token" => token} = params) do
    with :ok <- rate_limit(conn) do
      receive_push(conn, token, Map.delete(params, "token"))
    end
  end

  defp rate_limit(conn) do
    case RateLimit.check(:push, conn.remote_ip) do
      :ok ->
        :ok

      {:error, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms + 999, 1000)))
        |> error(:too_many_requests, "Rate limit exceeded")
    end
  end

  defp receive_push(conn, token, params) do
    case Monitoring.receive_push(token, params) do
      {:ok, result} ->
        json(conn, %{ok: true, status: result && result.status})

      {:error, :invalid_status} ->
        error(conn, :bad_request, ~s(status must be "up" or "down"))

      {:error, :not_found} ->
        error(conn, :not_found, "Monitor not found or not active")

      {:error, :not_running} ->
        error(conn, :service_unavailable, "Monitor is not running")
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{ok: false, error: message})
  end
end
