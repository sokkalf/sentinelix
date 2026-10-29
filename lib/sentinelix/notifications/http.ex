defmodule Sentinelix.Notifications.HTTP do
  @moduledoc """
  Shared HTTP client of the notification providers (Req).

  Retries are done by `Sentinelix.Notifications.Delivery`, so Req's retry
  step is disabled. Extra Req options can be configured with

      config :sentinelix, Sentinelix.Notifications, req_options: [...]

  which tests use to route requests through `Req.Test` (stub name
  `Sentinelix.Notifications`).
  """

  @timeout_ms 15_000

  @doc """
  Sends a request and returns `:ok` for a 2xx response, or
  `{:error, reason}`.
  """
  @spec request(keyword()) :: :ok | {:error, term()}
  def request(opts) do
    req_options =
      Application.get_env(:sentinelix, Sentinelix.Notifications, [])
      |> Keyword.get(:req_options, [])

    {headers, opts} = Keyword.pop(opts, :headers, [])

    [
      method: :post,
      retry: false,
      redirect: false,
      receive_timeout: @timeout_ms,
      connect_options: [timeout: @timeout_ms],
      headers: [{"user-agent", "Sentinelix/#{version()}"} | headers]
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(req_options)
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, truncate(body)}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp truncate(body), do: body

  defp version, do: Application.spec(:sentinelix, :vsn)
end
