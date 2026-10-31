defmodule SentinelixWeb.MonitorExportController do
  @moduledoc """
  `GET /monitors/export` downloads the monitors as YAML (see
  `Sentinelix.Monitoring.Export`), optionally only those matching the
  `selector` parameter (as in the monitor list). Push tokens are not
  included; use `mix sentinelix.export --push-tokens` for that.
  """
  use SentinelixWeb, :controller

  alias Sentinelix.Monitoring.Export

  def show(conn, params) do
    selector =
      case params["selector"] do
        text when is_binary(text) and text != "" -> text
        _none -> nil
      end

    case Export.export(selector: selector) do
      {:ok, yaml} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_download({:binary, yaml},
          filename: "sentinelix-monitors.yaml",
          content_type: "application/yaml",
          charset: "utf-8"
        )

      {:error, error} ->
        conn
        |> put_flash(:error, "Invalid selector: #{Exception.message(error)}")
        |> redirect(to: ~p"/monitors")
    end
  end
end
