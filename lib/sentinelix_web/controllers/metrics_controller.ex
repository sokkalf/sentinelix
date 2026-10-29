defmodule SentinelixWeb.MetricsController do
  @moduledoc """
  `GET /metrics` in the Prometheus text format (see `Sentinelix.Metrics`).

  Protected by a bearer token configured with the `METRICS_TOKEN`
  environment variable (`config :sentinelix, :metrics_token`):

    * no token configured – the endpoint is disabled and responds 404,
    * missing or wrong `Authorization: Bearer <token>` header – 401.
  """
  use SentinelixWeb, :controller

  def show(conn, _params) do
    case Application.get_env(:sentinelix, :metrics_token) do
      token when is_binary(token) and token != "" ->
        if authorized?(conn, token) do
          conn
          |> put_resp_content_type("text/plain; version=0.0.4", "utf-8")
          |> put_resp_header("cache-control", "no-store")
          |> send_resp(200, Sentinelix.Metrics.export())
        else
          conn
          |> put_resp_header("www-authenticate", ~s(Bearer realm="metrics"))
          |> send_resp(401, "Unauthorized\n")
        end

      _disabled ->
        send_resp(conn, 404, "Not Found\n")
    end
  end

  defp authorized?(conn, token) do
    conn
    |> get_req_header("authorization")
    |> Enum.any?(fn header ->
      case String.split(header, " ", parts: 2) do
        [scheme, given] ->
          String.downcase(scheme) == "bearer" and
            Plug.Crypto.secure_compare(String.trim(given), token)

        _ ->
          false
      end
    end)
  end
end
