defmodule Sentinelix.MonitoringFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Sentinelix.Monitoring` context.
  """

  alias Sentinelix.Monitoring

  @doc """
  Valid attributes for a monitor of the given type.
  """
  def valid_monitor_attrs(type \\ :http, attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "Monitor #{System.unique_integer([:positive])}",
      type: type,
      settings: valid_settings(type)
    })
  end

  def valid_settings(:http), do: %{url: "https://example.com/health"}
  def valid_settings(:tcp), do: %{host: "db.example.com", port: 5432}
  def valid_settings(:ping), do: %{host: "192.0.2.1"}
  def valid_settings(:dns), do: %{host: "example.com"}
  def valid_settings(:cert), do: %{host: "example.com"}
  def valid_settings(:push), do: %{}

  def valid_settings(:postgres),
    do: %{host: "db.example.com", database: "app", username: "monitor"}

  def monitor_fixture(type \\ :http, attrs \\ %{}) do
    {:ok, monitor} = type |> valid_monitor_attrs(attrs) |> Monitoring.create_monitor()
    monitor
  end

  def check_result_fixture(monitor, attrs \\ %{}) do
    {:ok, result} = Monitoring.record_result(monitor, Enum.into(attrs, %{status: :up}))
    result
  end

  def incident_fixture(monitor, attrs \\ %{}) do
    {:ok, incident} =
      Monitoring.open_incident(monitor, Enum.into(attrs, %{from_status: :up, to_status: :down}))

    incident
  end
end
