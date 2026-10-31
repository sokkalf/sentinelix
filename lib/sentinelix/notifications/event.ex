defmodule Sentinelix.Notifications.Event do
  @moduledoc """
  A notification about a monitor, as handed to the providers.

  `kind` is one of

    * `:down` – the monitor went down
    * `:up` – the monitor recovered
    * `:warning` – the monitor is up but reports a warning (e.g. a TLS
      certificate close to expiry)
    * `:warning_cleared` – the warning is gone
    * `:test` – a test notification, of a channel (from the settings page)
      or about a monitor (from its page)

  `title/1`, `text/1` and `to_map/1` render it in a provider-neutral way.
  """

  alias Sentinelix.Monitoring.{CheckResult, Monitor}

  @type kind :: :down | :up | :warning | :warning_cleared | :test

  @type t :: %__MODULE__{
          kind: kind(),
          monitor_id: pos_integer() | nil,
          monitor_name: String.t(),
          monitor_type: atom() | nil,
          status: atom() | nil,
          message: String.t() | nil,
          response_time_ms: non_neg_integer() | nil,
          status_code: integer() | nil,
          timestamp: DateTime.t(),
          url: String.t() | nil
        }

  @enforce_keys [:kind, :monitor_name, :timestamp]
  defstruct [
    :kind,
    :monitor_id,
    :monitor_name,
    :monitor_type,
    :status,
    :message,
    :response_time_ms,
    :status_code,
    :timestamp,
    :url
  ]

  @doc """
  Builds an event for a monitor from a check result.
  """
  @spec new(kind(), Monitor.t(), CheckResult.t() | nil) :: t()
  def new(kind, %Monitor{} = monitor, result) do
    result = result || %{}

    %__MODULE__{
      kind: kind,
      monitor_id: monitor.id,
      monitor_name: monitor.name,
      monitor_type: monitor.type,
      status: Map.get(result, :status),
      message: Map.get(result, :message),
      response_time_ms: Map.get(result, :response_time_ms),
      status_code: Map.get(result, :status_code),
      timestamp: Map.get(result, :checked_at) || DateTime.utc_now(),
      url: monitor_url(monitor.id)
    }
  end

  @doc """
  A test event, used by "Send test notification": of a channel (without a
  monitor), or about a monitor, sent to the channels that notify it.
  """
  @spec test(Monitor.t() | nil) :: t()
  def test(monitor \\ nil)

  def test(nil) do
    %__MODULE__{
      kind: :test,
      monitor_name: "Sentinelix",
      message: "This is a test notification from Sentinelix. If you can read it, it works!",
      timestamp: DateTime.utc_now(),
      url: SentinelixWeb.Endpoint.url()
    }
  end

  def test(%Monitor{} = monitor) do
    %__MODULE__{
      kind: :test,
      monitor_id: monitor.id,
      monitor_name: monitor.name,
      monitor_type: monitor.type,
      message:
        "This is a test notification from Sentinelix. " <>
          "This channel is notified when #{monitor.name} goes down or recovers.",
      timestamp: DateTime.utc_now(),
      url: monitor_url(monitor.id)
    }
  end

  @doc """
  The link to a monitor's page.
  """
  @spec monitor_url(pos_integer()) :: String.t()
  def monitor_url(id), do: SentinelixWeb.Endpoint.url() <> "/monitors/#{id}"

  @doc """
  A short label for the event kind, e.g. `"DOWN"`.
  """
  @spec label(t() | kind()) :: String.t()
  def label(%__MODULE__{kind: kind}), do: label(kind)
  def label(:down), do: "DOWN"
  def label(:up), do: "UP"
  def label(:warning), do: "WARNING"
  def label(:warning_cleared), do: "OK"
  def label(:test), do: "TEST"

  @doc """
  A one-line summary, e.g. `"[DOWN] Homepage is down"`.
  """
  @spec title(t()) :: String.t()
  def title(%__MODULE__{} = event), do: "[#{label(event)}] #{headline(event)}"

  defp headline(%{kind: :down, monitor_name: name}), do: "#{name} is down"
  defp headline(%{kind: :up, monitor_name: name}), do: "#{name} is back up"
  defp headline(%{kind: :warning, monitor_name: name}), do: "#{name} has a warning"
  defp headline(%{kind: :warning_cleared, monitor_name: name}), do: "#{name} warning cleared"
  defp headline(%{kind: :test, monitor_id: nil}), do: "Test notification"
  defp headline(%{kind: :test, monitor_name: name}), do: "Test notification for #{name}"

  @doc """
  The details as plain text lines (without the title).
  """
  @spec details(t()) :: [String.t()]
  def details(%__MODULE__{} = event) do
    [
      event.message,
      event.response_time_ms && "Response time: #{event.response_time_ms} ms",
      "Time: #{format_timestamp(event.timestamp)}",
      event.url
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  @doc """
  Title and details as a multi-line plain text message.
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{} = event), do: Enum.join([title(event) | details(event)], "\n")

  @doc """
  A JSON-encodable map of the event (used e.g. by the generic webhook).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      event: event.kind,
      title: title(event),
      text: text(event),
      monitor: %{
        id: event.monitor_id,
        name: event.monitor_name,
        type: event.monitor_type,
        url: event.url
      },
      status: event.status,
      message: event.message,
      response_time_ms: event.response_time_ms,
      status_code: event.status_code,
      timestamp: DateTime.to_iso8601(event.timestamp)
    }
  end

  @doc false
  def format_timestamp(%DateTime{} = timestamp),
    do: timestamp |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S %Z")
end
