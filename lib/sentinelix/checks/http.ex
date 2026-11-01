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

  ## Response assertions

  Once the status code is accepted, the monitor's `assertions` (see
  `Sentinelix.Monitoring.Settings.Assertion`) are evaluated in order; all
  of them must pass. The first one that fails makes the check `:down` with
  a message like `JSON queue.depth is "250", expected < 100` and its
  (0-based) index in `meta: %{failed_assertion: index}`. An unaccepted
  status code is `:down` without evaluating them.

    * The response body is only read when an assertion needs it (`body`
      and `json` sources), and at most `max_body_bytes` of it (default
      1 MiB, configurable with `config :sentinelix, Sentinelix.Checks.HTTP,
      max_body_bytes: ...`). Body and JSON assertions on a larger body
      fail with "Response body exceeds N bytes". Otherwise the body is
      discarded as it arrives.
    * Compression isn't requested, so the body is tested as sent.
    * Regular expressions run with Unicode semantics only when the body is
      valid UTF-8, byte-wise otherwise. Patterns are entered by admins; a
      pattern with catastrophic backtracking is bounded by the monitor's
      `timeout_ms`, after which the worker kills the check.

  In tests, requests are routed through `Req.Test` with
  `config :sentinelix, Sentinelix.Checks.HTTP, req_options: [plug: {Req.Test, Sentinelix.Checks.HTTP}]`.
  """

  @behaviour Sentinelix.Checks.Check

  alias Plug.Conn.Status
  alias Sentinelix.Checks
  alias Sentinelix.Checks.Comparison
  alias Sentinelix.Monitoring.{Monitor, Settings}
  alias Sentinelix.Monitoring.Settings.Assertion

  @default_max_body_bytes 1_048_576
  @truncated :sentinelix_body_truncated

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
      {:ok, response, elapsed_ms} -> evaluate(settings, response, elapsed_ms)
      {:error, exception, elapsed_ms} -> error_result(exception, elapsed_ms)
    end
  end

  @doc """
  The check result for a response: its status (`evaluate_status/3`) and,
  if that is accepted, the response assertions of the settings.
  """
  @spec evaluate(Settings.t(), Req.Response.t(), non_neg_integer()) ::
          Sentinelix.Checks.Check.result()
  def evaluate(%Settings{} = settings, %Req.Response{status: status} = response, elapsed_ms) do
    case {evaluate_status(settings, status, elapsed_ms), settings.assertions || []} do
      {{:up, details}, [_ | _] = assertions} ->
        case evaluate_assertions(assertions, response) do
          :ok ->
            {:up, %{details | message: "#{details.message}, #{passed(length(assertions))}"}}

          {:error, index, message} ->
            {:down, Map.merge(details, %{message: message, meta: %{failed_assertion: index}})}
        end

      {result, _assertions} ->
        result
    end
  end

  defp passed(1), do: "1 assertion passed"
  defp passed(count), do: "#{count} assertions passed"

  @doc """
  Evaluates assertions in order against a response. Returns `:ok` or the
  (0-based) index and failure message of the first one that fails.
  """
  @spec evaluate_assertions([Assertion.t()], Req.Response.t()) ::
          :ok | {:error, non_neg_integer(), String.t()}
  def evaluate_assertions(assertions, %Req.Response{} = response) do
    assertions
    |> Enum.with_index()
    |> Enum.reduce_while(%{response: response, json: nil}, fn {assertion, index}, context ->
      case check_assertion(assertion, context) do
        {:ok, context} -> {:cont, context}
        {:error, message} -> {:halt, {:error, index, message}}
      end
    end)
    |> case do
      {:error, _index, _message} = error -> error
      _context -> :ok
    end
  end

  defp check_assertion(%Assertion{source: "header", path: name} = assertion, context) do
    value =
      case Req.Response.get_header(context.response, String.downcase(name)) do
        [] -> nil
        values -> Enum.join(values, ", ")
      end

    with :ok <- compare(assertion, "Header #{name}", value), do: {:ok, context}
  end

  defp check_assertion(%Assertion{source: "body"} = assertion, context) do
    with {:ok, body} <- body(context.response),
         :ok <- compare(assertion, "Body", body),
         do: {:ok, context}
  end

  defp check_assertion(%Assertion{source: "json", path: path} = assertion, context) do
    with {:ok, json, context} <- json(context),
         {:ok, segments} <- json_path(path),
         :ok <- compare(assertion, "JSON #{path}", json_value(json, segments)),
         do: {:ok, context}
  end

  defp body(%Req.Response{body: body} = response) do
    if Req.Response.get_private(response, @truncated) do
      {:error, "Response body exceeds #{max_body_bytes()} bytes"}
    else
      {:ok, body_to_binary(body)}
    end
  end

  # Decoded once, for all JSON assertions.
  defp json(%{json: nil} = context) do
    with {:ok, body} <- body(context.response) do
      json =
        case JSON.decode(body) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, "Response body is not valid JSON"}
        end

      json(%{context | json: json})
    end
  end

  defp json(%{json: {:ok, json}} = context), do: {:ok, json, context}
  defp json(%{json: {:error, message}}), do: {:error, message}

  defp json_path(path) do
    case Settings.parse_json_path(path) do
      {:ok, segments} -> {:ok, segments}
      :error -> {:error, "Invalid JSON path #{inspect(path)}"}
    end
  end

  # The value at a path as text (strings as is, other values as JSON), or
  # nil when the path doesn't exist.
  defp json_value(json, segments) do
    case fetch_path(json, segments) do
      {:ok, value} when is_binary(value) -> value
      {:ok, value} -> JSON.encode!(value)
      {:error, :not_found} -> nil
    end
  end

  @doc """
  The value at a parsed JSON path (see
  `Sentinelix.Monitoring.Settings.parse_json_path/1`): keys of objects and
  0-based indexes of arrays.
  """
  @spec fetch_path(term(), [String.t()]) :: {:ok, term()} | {:error, :not_found}
  def fetch_path(value, []), do: {:ok, value}

  def fetch_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> {:error, :not_found}
    end
  end

  def fetch_path(list, [index | rest]) when is_list(list) do
    case Integer.parse(index) do
      {i, ""} when i >= 0 and i < length(list) -> fetch_path(Enum.at(list, i), rest)
      _ -> {:error, :not_found}
    end
  end

  def fetch_path(_value, _segments), do: {:error, :not_found}

  defp compare(%Assertion{comparison: comparison, value: expected} = assertion, subject, actual) do
    case Comparison.compare(actual, comparison, expected,
           case_sensitive: assertion.case_sensitive != false
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, failure_message(subject, actual, comparison, expected, reason)}
    end
  end

  defp failure_message(subject, nil, _comparison, _expected, _reason) do
    if String.starts_with?(subject, "JSON"),
      do: "#{subject} not found",
      else: "#{subject} missing"
  end

  defp failure_message(subject, _actual, _comparison, expected, " (invalid regular expression)"),
    do: "#{subject}: invalid regular expression /#{Comparison.truncate(expected)}/"

  defp failure_message("Body", _actual, comparison, expected, _reason)
       when comparison in ~w(contains not_contains regex not_regex) do
    shown = Comparison.truncate(expected)

    case comparison do
      "contains" -> ~s(Body does not contain "#{shown}")
      "not_contains" -> ~s(Body contains "#{shown}")
      "regex" -> "Body does not match /#{shown}/"
      "not_regex" -> "Body matches /#{shown}/"
    end
  end

  defp failure_message(subject, actual, comparison, expected, reason) do
    ~s(#{subject} is "#{Comparison.truncate(actual)}", ) <>
      Comparison.describe(comparison, expected) <> reason
  end

  defp body_to_binary(body) when is_binary(body), do: body
  defp body_to_binary(nil), do: ""
  defp body_to_binary(body), do: IO.iodata_to_binary(body)

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
      receive_timeout: timeout,
      into: body_collector(settings)
    ]
    |> put_body(settings.body)
    |> Keyword.merge(req_options())
    |> Req.new()
    |> Req.Request.append_request_steps(
      sentinelix_connect_options: &put_connect_options(&1, timeout, settings.verify_tls != false)
    )
  end

  # Reads the body only when an assertion needs it, up to the cap.
  defp body_collector(settings) do
    # (Keyword monitors read the body too.)
    if settings.keyword || Enum.any?(settings.assertions || [], &Assertion.needs_body?/1),
      do: collect_body(max_body_bytes()),
      else: &discard_body/2
  end

  defp discard_body({:data, _data}, acc), do: {:cont, acc}

  defp collect_body(max) do
    fn {:data, data}, {request, response} ->
      body = response.body
      room = max - byte_size(body)

      if byte_size(data) > room do
        response =
          %{response | body: body <> binary_part(data, 0, room)}
          |> Req.Response.put_private(@truncated, true)

        {:halt, {request, response}}
      else
        {:cont, {request, %{response | body: body <> data}}}
      end
    end
  end

  defp max_body_bytes do
    :sentinelix
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_body_bytes, @default_max_body_bytes)
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
