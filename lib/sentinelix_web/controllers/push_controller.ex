defmodule SentinelixWeb.PushController do
  @moduledoc """
  Public push (heartbeat) endpoint for push monitors.

      GET|POST /api/push/:token?status=up|down&msg=...&ping=<ms>

  No authentication: the token identifies (and authorizes) the monitor. The
  lookup is a single indexed query, so the endpoint is cheap enough to be
  put behind a rate limiter or hit frequently. Parameters can also be sent
  as a form or JSON body with POST. See
  `Sentinelix.Monitoring.receive_push/2`.

  Responses (JSON):

    * `200 {"ok": true, "status": "up"}` – recorded; `status` is the
      monitor's resulting status (`up`, `down`, `pending` or `maintenance`)
    * `400` – invalid `status` parameter
    * `404` – unknown token or the monitor is disabled
    * `503` – the monitoring engine isn't running the monitor
  """

  use SentinelixWeb, :controller

  alias Sentinelix.Monitoring

  def push(conn, %{"token" => token} = params) do
    case Monitoring.receive_push(token, Map.delete(params, "token")) do
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
