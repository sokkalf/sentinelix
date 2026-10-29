defmodule Sentinelix.Notifications.Delivery do
  @moduledoc """
  Sends an event to a channel through its provider, with retries.

  Provider errors, exceptions and exits are turned into `{:error, reason}`,
  so a broken provider can't take anything down. `deliver_with_retry/3`
  retries failed sends with exponential backoff.

  Defaults (overridable per call and with
  `config :sentinelix, Sentinelix.Notifications, ...`):

    * `:max_attempts` – 3
    * `:backoff_ms` – 5000; attempt `n` is retried after
      `backoff_ms * 2^(n-1)` ms
  """

  require Logger

  alias Sentinelix.Notifications.{Channel, Event, Provider}

  @defaults [max_attempts: 3, backoff_ms: 5_000]

  @doc """
  Sends `event` to `channel` once.
  """
  @spec deliver(Channel.t(), Event.t()) :: :ok | {:error, term()}
  def deliver(%Channel{} = channel, %Event{} = event) do
    provider = Provider.for_type(channel.type)

    case provider.send(channel, event) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_return, other}}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Sends `event` to `channel`, retrying failures. Logs every failure and
  returns the last error after the final attempt.
  """
  @spec deliver_with_retry(Channel.t(), Event.t(), keyword()) :: :ok | {:error, term()}
  def deliver_with_retry(channel, event, opts \\ []) do
    opts =
      @defaults
      |> Keyword.merge(Application.get_env(:sentinelix, Sentinelix.Notifications, []))
      |> Keyword.merge(opts)

    attempt(channel, event, 1, opts[:max_attempts], opts[:backoff_ms])
  end

  defp attempt(channel, event, n, max, backoff) do
    case deliver(channel, event) do
      :ok ->
        Logger.info(
          "Sent #{event.kind} notification for #{inspect(event.monitor_name)} " <>
            "to channel #{inspect(channel.name)}"
        )

        :ok

      {:error, reason} when n < max ->
        delay = backoff * Integer.pow(2, n - 1)

        Logger.warning(
          "Notification to channel #{inspect(channel.name)} failed " <>
            "(attempt #{n}/#{max}, retrying in #{delay} ms): #{format_error(reason)}"
        )

        Process.sleep(delay)
        attempt(channel, event, n + 1, max, backoff)

      {:error, reason} = error ->
        Logger.error(
          "Notification to channel #{inspect(channel.name)} failed after #{n} attempt(s), " <>
            "giving up: #{format_error(reason)}"
        )

        error
    end
  end

  @doc """
  A human readable description of a delivery error.
  """
  @spec format_error(term()) :: String.t()
  def format_error({:http_status, status, body}) when is_binary(body) and body != "",
    do: "HTTP #{status}: #{body}"

  def format_error({:http_status, status, _body}), do: "HTTP #{status}"
  def format_error(exception) when is_exception(exception), do: Exception.message(exception)
  def format_error(reason), do: inspect(reason)
end
