defmodule SentinelixWeb.HealthController do
  @moduledoc """
  `GET /healthz` for container health checks (no authentication).

  Responds 200 with `{"status": "ok", "db": "ok"}` when the database
  answers, 503 with `{"status": "error", "db": "error"}` otherwise.
  """
  use SentinelixWeb, :controller

  def show(conn, _params) do
    {status, body} =
      case Sentinelix.Health.check() do
        {:ok, body} -> {:ok, body}
        {:error, body} -> {:service_unavailable, body}
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(body)
  end
end
