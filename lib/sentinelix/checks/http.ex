defmodule Sentinelix.Checks.HTTP do
  @moduledoc """
  HTTP(S) check.

  Sends a request built from the monitor's settings (`url`, `method`,
  `headers`, `body`) and reports `:up` when the final response status is one
  of the accepted status codes (see
  `Sentinelix.Monitoring.Settings.accepted_status?/2`; by default 200–399
  when following redirects and 200–299 otherwise).

    * Redirects are followed up to `max_redirects` when `follow_redirects` is
      set; relative `Location` headers are resolved against the request URL.
      Exceeding the limit is reported as `:down`.
    * `verify_tls: false` disables certificate verification (for every hop
      that uses https).
    * The monitor's `timeout_ms` is used for connecting and receiving.
    * Requests carry a `User-Agent: Sentinelix/<version>` header unless the
      monitor's headers set one.
    * The engine does its own retries, so Req's retry step is disabled.

  The response body is not kept in the result. Checks that need it (e.g. a
  keyword check) can use `request/1`.

  In tests, requests are routed through `Req.Test` with
  `config :sentinelix, Sentinelix.Checks.HTTP, req_options: [plug: {Req.Test, Sentinelix.Checks.HTTP}]`.
  """

  @behaviour Sentinelix.Checks.Check

  alias Plug.Conn.Status
  alias Sentinelix.Checks
  alias Sentinelix.Monitoring.{Monitor, Settings}

  @methods %{
    "GET" => :get,
    "HEAD" => :head,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete,
    "OPTIONS" => :options
  }

  @impl true
  def run(%Monitor{settings: settings} = monitor) do
    case request(monitor) do
      {:ok, %Req.Response{status: status}, elapsed_ms} ->
        evaluate_status(settings, status, elapsed_ms)

      {:error, exception, elapsed_ms} ->
        error_result(exception, elapsed_ms)
    end
  end

  @doc """
  The check result for a response status: `:up` if it is accepted by the
  settings, `:down` otherwise.
  """
  @spec evaluate_status(Settings.t(), non_neg_integer(), non_neg_integer()) ::
          Sentinelix.Checks.Check.result()
  def evaluate_status(%Settings{} = settings, status, elapsed_ms) do
    details = %{response_time_ms: elapsed_ms, status_code: status}

    if Settings.accepted_status?(settings, status) do
      {:up, Map.put(details, :message, status_line(status))}
    else
      message =
        "Unexpected status #{status_line(status)} " <>
          "(accepted: #{format_ranges(Settings.accepted_status_ranges(settings))})"

      {:down, Map.put(details, :message, message)}
    end
  end

  @doc """
  The `:down` check result for a failed request.
  """
  @spec error_result(Exception.t(), non_neg_integer()) :: Sentinelix.Checks.Check.result()
  def error_result(exception, elapsed_ms),
    do: {:down, %{response_time_ms: elapsed_ms, message: error_message(exception)}}

  @doc """
  Performs the HTTP request for a monitor.

  Returns the final response (after redirects) or the exception, together
  with the elapsed time in milliseconds.
  """
  @spec request(Monitor.t()) ::
          {:ok, Req.Response.t(), non_neg_integer()} | {:error, Exception.t(), non_neg_integer()}
  def request(%Monitor{} = monitor) do
    req = build_request(monitor)
    started = System.monotonic_time()
    result = Req.request(req)

    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    case result do
      {:ok, response} -> {:ok, response, elapsed_ms}
      {:error, exception} -> {:error, exception, elapsed_ms}
    end
  end

  @doc false
  @spec build_request(Monitor.t()) :: Req.Request.t()
  def build_request(%Monitor{settings: %Settings{} = settings, timeout_ms: timeout}) do
    [
      method: Map.fetch!(@methods, settings.method || "GET"),
      url: settings.url,
      headers: headers(settings),
      redirect: settings.follow_redirects != false,
      max_redirects: settings.max_redirects || 10,
      redirect_log_level: false,
      retry: false,
      decode_body: false,
      receive_timeout: timeout
    ]
    |> put_body(settings.body)
    |> Keyword.merge(req_options())
    |> Req.new()
    |> Req.Request.append_request_steps(
      sentinelix_connect_options: &put_connect_options(&1, timeout, settings.verify_tls != false)
    )
  end

  defp headers(settings) do
    custom =
      Map.new(settings.headers || %{}, fn {name, value} -> {String.downcase(name), value} end)

    Map.merge(%{"user-agent" => Checks.user_agent()}, custom)
  end

  defp put_body(options, body) when body in [nil, ""], do: options
  defp put_body(options, body), do: Keyword.put(options, :body, body)

  defp req_options do
    :sentinelix |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
  end

  # Runs as a request step so that it is re-evaluated for every redirect hop:
  # TLS options must only be given for https, `:gen_tcp` rejects them.
  # Failed handshakes are reported in the result; keep `:ssl` from also
  # logging every TLS alert.
  defp put_connect_options(request, timeout, verify_tls?) do
    transport_opts =
      case {request.url.scheme, verify_tls?} do
        {"https", true} -> [log_level: :error]
        {"https", false} -> [log_level: :error, verify: :verify_none]
        _ -> []
      end

    connect_options = [timeout: timeout, transport_opts: transport_opts]
    %{request | options: Map.put(request.options, :connect_options, connect_options)}
  end

  @doc false
  def status_line(status) do
    case reason_phrase(status) do
      nil -> Integer.to_string(status)
      phrase -> "#{status} #{phrase}"
    end
  end

  defp reason_phrase(status) do
    Status.reason_phrase(status)
  rescue
    ArgumentError -> nil
  end

  defp format_ranges(ranges) do
    Enum.map_join(ranges, ", ", fn
      first..first//_ -> Integer.to_string(first)
      first..last//_ -> "#{first}-#{last}"
    end)
  end

  defp error_message(%Req.TooManyRedirectsError{max_redirects: max}),
    do: "Too many redirects (more than #{max})"

  defp error_message(%Req.TransportError{reason: :timeout}), do: "Timed out"

  defp error_message(%{__exception__: true} = exception),
    do: exception |> Exception.message() |> String.trim()
end
