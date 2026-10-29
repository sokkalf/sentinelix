defmodule Sentinelix.Checks.Keyword do
  @moduledoc """
  HTTP keyword / JSON check.

  Performs the request of an HTTP check (see `Sentinelix.Checks.HTTP`; same
  settings, redirects, TLS and status code handling) and then inspects the
  response body:

    * Without `json_path`, the body must contain `keyword`.
    * With `json_path` (a dot-path like `data.items.0.status`, see
      `Sentinelix.Monitoring.Settings.parse_json_path/1`), the body is
      decoded as JSON and the value at that path must equal `keyword`.
      Strings are compared as is, other values by their JSON encoding
      (e.g. `true`, `42`, `null`). A body that isn't JSON or a path that
      doesn't exist is reported as `:down`.

  `case_sensitive: false` compares case-insensitively and `invert_keyword:
  true` inverts the outcome ("must not contain" / "must not equal"). An
  unaccepted status code is always `:down`, regardless of the keyword.
  """

  @behaviour Sentinelix.Checks.Check

  alias Sentinelix.Checks.HTTP
  alias Sentinelix.Monitoring.{Monitor, Settings}

  @max_shown_length 100

  @impl true
  def run(%Monitor{settings: settings} = monitor) do
    case HTTP.request(monitor) do
      {:ok, %Req.Response{status: status, body: body}, elapsed_ms} ->
        if Settings.accepted_status?(settings, status) do
          {result, message} = evaluate(body_to_binary(body), settings)
          {result, %{response_time_ms: elapsed_ms, status_code: status, message: message}}
        else
          HTTP.evaluate_status(settings, status, elapsed_ms)
        end

      {:error, exception, elapsed_ms} ->
        HTTP.error_result(exception, elapsed_ms)
    end
  end

  @doc """
  Evaluates a response body against the keyword settings.

  Returns `{:up | :down, message}`.
  """
  @spec evaluate(binary(), Settings.t()) :: {:up | :down, String.t()}
  def evaluate(body, %Settings{json_path: path} = settings) when path in [nil, ""] do
    found? = contains?(body, settings.keyword, settings.case_sensitive != false)
    keyword = shorten(settings.keyword)

    case {found?, settings.invert_keyword == true} do
      {true, false} -> {:up, ~s(Keyword "#{keyword}" found)}
      {false, false} -> {:down, ~s(Keyword "#{keyword}" not found)}
      {false, true} -> {:up, ~s(Keyword "#{keyword}" not found, as expected)}
      {true, true} -> {:down, ~s(Keyword "#{keyword}" found but must not be present)}
    end
  end

  def evaluate(body, %Settings{json_path: path} = settings) do
    with {:ok, segments} <- Settings.parse_json_path(path),
         {:ok, json} <- decode(body),
         {:ok, value} <- fetch_path(json, segments) do
      actual = to_comparable(value)
      equal? = equal?(actual, settings.keyword, settings.case_sensitive != false)
      expected = shorten(settings.keyword)
      shown = shorten(actual)

      case {equal?, settings.invert_keyword == true} do
        {true, false} ->
          {:up, ~s(#{path} is "#{shown}")}

        {false, false} ->
          {:down, ~s(#{path} is "#{shown}", expected "#{expected}")}

        {false, true} ->
          {:up, ~s(#{path} is "#{shown}", not "#{expected}" as required)}

        {true, true} ->
          {:down, ~s(#{path} is "#{shown}" but must not be)}
      end
    else
      :error -> {:down, "Invalid JSON path #{inspect(path)}"}
      {:error, :invalid_json} -> {:down, "Response body is not valid JSON"}
      {:error, :not_found} -> {:down, "JSON path #{path} not found in the response"}
    end
  end

  defp contains?(_body, keyword, _case_sensitive?) when keyword in [nil, ""], do: true
  defp contains?(body, keyword, true), do: String.contains?(body, keyword)

  defp contains?(body, keyword, false),
    do: String.contains?(String.downcase(body), String.downcase(keyword))

  defp equal?(actual, expected, true), do: actual == (expected || "")

  defp equal?(actual, expected, false),
    do: String.downcase(actual) == String.downcase(expected || "")

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @doc false
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

  defp to_comparable(value) when is_binary(value), do: value
  defp to_comparable(value), do: JSON.encode!(value)

  defp body_to_binary(body) when is_binary(body), do: body
  defp body_to_binary(nil), do: ""
  defp body_to_binary(body), do: IO.iodata_to_binary(body)

  defp shorten(nil), do: ""

  defp shorten(text) do
    if String.length(text) > @max_shown_length,
      do: String.slice(text, 0, @max_shown_length) <> "…",
      else: text
  end
end
