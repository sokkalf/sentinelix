defmodule SentinelixWeb.EventController do
  @moduledoc """
  Public endpoint for posting events to a monitor of any type.

      POST /api/v1/events/:token

  No authentication: the monitor's event token identifies (and authorizes)
  it; it only allows appending events. Parameters as a form or JSON body:
  `title` (required), `message`, `severity` (`info`, `warning` or `ok`),
  `key` and `ttl`; any other fields are stored as metadata. See
  `Sentinelix.Monitoring.Events.record_event/3`. Requests are rate limited
  per client IP (`:events` bucket of `Sentinelix.RateLimit`,
  `EVENTS_RATE_LIMIT` in production).

  Responses (JSON):

    * `201 {"ok": true, "status": "warning"}` – recorded; `status` is the
      monitor's resulting status
    * `400` – invalid parameters (`error` says which)
    * `404` – unknown token or the monitor is disabled
    * `429` – rate limit exceeded (with a `retry-after` header)
  """

  use SentinelixWeb, :controller

  alias Sentinelix.{Monitoring, RateLimit}
  alias Sentinelix.Monitoring.{Events, Monitor}

  def create(conn, %{"token" => token} = params) do
    with :ok <- rate_limit(conn) do
      case Monitoring.get_monitor_by_event_token(token) do
        %Monitor{enabled: true} = monitor -> record(conn, monitor, Map.delete(params, "token"))
        _ -> error(conn, :not_found, "Monitor not found or not active")
      end
    end
  end

  defp record(conn, monitor, params) do
    case Events.record_event(monitor, params) do
      {:ok, _event, status} ->
        conn
        |> put_status(:created)
        |> json(%{ok: true, status: status})

      {:error, changeset} ->
        error(conn, :bad_request, Events.error_message(changeset))
    end
  end

  defp rate_limit(conn) do
    case RateLimit.check(:events, conn.remote_ip) do
      :ok ->
        :ok

      {:error, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms + 999, 1000)))
        |> error(:too_many_requests, "Rate limit exceeded")
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{ok: false, error: message})
  end
end
