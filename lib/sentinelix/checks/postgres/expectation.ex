defmodule Sentinelix.Checks.Postgres.Expectation do
  @moduledoc """
  Assertions on the result of a PostgreSQL check's query.

  ## Value

  The value compared with `expected_value` is the **first column of the
  first row**, converted to text (`to_text/1`):

  | PostgreSQL value           | Text                                     |
  | -------------------------- | ---------------------------------------- |
  | `NULL`                     | `NULL`                                   |
  | boolean                    | `true` / `false`                         |
  | integer, numeric, float    | the number, e.g. `42`, `1.50`, `0.1`     |
  | `NaN`, `±Infinity`         | `NaN`, `Infinity`, `-Infinity`           |
  | date, time, timestamp(tz)  | ISO 8601, e.g. `2026-10-30T12:00:00.5Z`  |
  | interval                   | e.g. `1 year 2 mons 3 days 04:05:06`     |
  | text-like                  | the text                                 |
  | binary data (bytea, uuid)  | hex, e.g. `\\x00ff` – cast to `text` in the query for UUIDs |
  | array                      | `{1,2,3}`                                |
  | json(b)                    | JSON                                     |

  Comparisons (`comparisons/0`):

    * `equals`, `not_equals` – exact text comparison.
    * `contains` – the text contains `expected_value`.
    * `regex` – the text matches the regular expression `expected_value`.
    * `<`, `<=`, `>`, `>=` – numeric: both sides are parsed as decimal
      numbers; a value that isn't a (finite) number fails the check.

  A query that returns no rows fails a value assertion.

  ## Row count

  `expected_rows` is compared with the number of rows using
  `rows_comparisons/0` (e.g. `equals 0` for "no stuck jobs", `>= 1` for
  "at least one row").
  """

  @comparisons ~w(equals not_equals contains regex < <= > >=)
  @rows_comparisons ~w(equals not_equals < <= > >=)
  @numeric ~w(< <= > >=)
  @max_shown 100

  @doc "Comparisons for the value."
  def comparisons, do: @comparisons

  @doc "Comparisons for the row count."
  def rows_comparisons, do: @rows_comparisons

  @doc "Whether a comparison is numeric."
  def numeric?(comparison), do: comparison in @numeric

  @doc """
  Checks the value assertion (if `expected_value` is set) of a query
  result. Returns `{:ok, message}` (with the value shown) or
  `{:error, message}`.
  """
  @spec check_value(Postgrex.Result.t(), String.t() | nil, String.t()) ::
          :skip | {:ok, String.t()} | {:error, String.t()}
  def check_value(_result, nil, _comparison), do: :skip

  def check_value(%Postgrex.Result{rows: [[value | _] | _]}, expected, comparison) do
    actual = to_text(value)
    shown = ~s(got "#{truncate(actual)}")

    case compare(actual, comparison, expected) do
      :ok -> {:ok, shown}
      {:error, reason} -> {:error, "#{shown}, #{describe(comparison, expected)}#{reason}"}
    end
  end

  def check_value(%Postgrex.Result{}, expected, comparison),
    do: {:error, "got no rows, #{describe(comparison, expected)}"}

  @doc """
  Checks the row count assertion (if `expected_rows` is set) of a query
  result.
  """
  @spec check_rows(Postgrex.Result.t(), non_neg_integer() | nil, String.t()) ::
          :skip | :ok | {:error, String.t()}
  def check_rows(_result, nil, _comparison), do: :skip

  def check_rows(%Postgrex.Result{num_rows: rows}, expected, comparison) do
    rows = rows || 0

    case compare(Integer.to_string(rows), comparison, Integer.to_string(expected)) do
      :ok -> :ok
      {:error, _} -> {:error, "got #{pluralize_rows(rows)}, #{describe(comparison, expected)}"}
    end
  end

  @doc """
  Compares a value (as text) with the expected value.
  """
  @spec compare(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def compare(actual, comparison, expected) when comparison in @numeric do
    with {:ok, actual} <- parse_number(actual),
         {:ok, expected} <- parse_number(expected) do
      if compare_numbers(Decimal.compare(actual, expected), comparison),
        do: :ok,
        else: {:error, ""}
    else
      :error -> {:error, " (not a number)"}
    end
  end

  def compare(actual, comparison, expected) do
    matches? =
      case comparison do
        "equals" -> actual == expected
        "not_equals" -> actual != expected
        "contains" -> String.contains?(actual, expected)
        "regex" -> regex_match?(expected, actual)
      end

    case matches? do
      true -> :ok
      false -> {:error, ""}
      :invalid -> {:error, " (invalid regular expression)"}
    end
  end

  defp regex_match?(pattern, text) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, text)
      {:error, _} -> :invalid
    end
  end

  defp compare_numbers(order, "<"), do: order == :lt
  defp compare_numbers(order, "<="), do: order in [:lt, :eq]
  defp compare_numbers(order, ">"), do: order == :gt
  defp compare_numbers(order, ">="), do: order in [:gt, :eq]

  @doc """
  Parses a finite decimal number (surrounding whitespace is ignored).
  """
  @spec parse_number(String.t()) :: {:ok, Decimal.t()} | :error
  def parse_number(text) do
    case Decimal.parse(String.trim(text)) do
      {decimal, ""} ->
        if Decimal.inf?(decimal) or Decimal.nan?(decimal), do: :error, else: {:ok, decimal}

      _ ->
        :error
    end
  end

  defp describe("equals", expected), do: ~s(expected "#{expected}")
  defp describe("not_equals", expected), do: ~s(expected anything but "#{expected}")
  defp describe("contains", expected), do: ~s(expected it to contain "#{expected}")
  defp describe("regex", expected), do: "expected it to match /#{expected}/"
  defp describe(operator, expected), do: "expected #{operator} #{expected}"

  defp truncate(text) do
    if String.length(text) > @max_shown,
      do: String.slice(text, 0, @max_shown) <> "…",
      else: text
  end

  defp pluralize_rows(1), do: "1 row"
  defp pluralize_rows(n), do: "#{n} rows"

  @doc """
  Converts a value returned by Postgrex to text, see the moduledoc.
  """
  @spec to_text(term()) :: String.t()
  def to_text(nil), do: "NULL"
  def to_text(value) when is_boolean(value), do: Atom.to_string(value)
  def to_text(value) when is_integer(value), do: Integer.to_string(value)
  def to_text(value) when is_float(value), do: Float.to_string(value)
  def to_text(:NaN), do: "NaN"
  def to_text(:inf), do: "Infinity"
  def to_text(:"-inf"), do: "-Infinity"
  def to_text(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  def to_text(%Date{} = value), do: Date.to_iso8601(value)
  def to_text(%Time{} = value), do: value |> trim_fraction() |> Time.to_iso8601()

  def to_text(%NaiveDateTime{} = value),
    do: value |> trim_fraction() |> NaiveDateTime.to_iso8601()

  def to_text(%DateTime{} = value), do: value |> trim_fraction() |> DateTime.to_iso8601()
  def to_text(%Postgrex.Interval{} = value), do: interval_to_text(value)

  def to_text(value) when is_binary(value) do
    if String.printable?(value),
      do: value,
      else: "\\x" <> Base.encode16(value, case: :lower)
  end

  def to_text(value) when is_list(value), do: "{" <> Enum.map_join(value, ",", &to_text/1) <> "}"

  def to_text(value) when is_map(value) and not is_struct(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  def to_text(value), do: inspect(value)

  # Postgrex returns microsecond precision; show only significant digits
  # (as PostgreSQL does).
  defp trim_fraction(%{microsecond: {microsecond, _precision}} = value) do
    digits = microsecond |> Integer.to_string() |> String.pad_leading(6, "0")

    precision =
      if microsecond == 0, do: 0, else: digits |> String.trim_trailing("0") |> byte_size()

    %{value | microsecond: {microsecond, precision}}
  end

  defp interval_to_text(%Postgrex.Interval{months: months, days: days, secs: secs} = interval) do
    microsecs = interval.microsecs
    years = div(months, 12)
    months = rem(months, 12)
    total = secs * 1_000_000 + microsecs

    time =
      if total != 0 or (years == 0 and months == 0 and days == 0) do
        sign = if total < 0, do: "-", else: ""
        total = abs(total)
        seconds = div(total, 1_000_000)
        fraction = rem(total, 1_000_000)

        clock =
          [div(seconds, 3600), div(rem(seconds, 3600), 60), rem(seconds, 60)]
          |> Enum.map_join(":", &(&1 |> Integer.to_string() |> String.pad_leading(2, "0")))

        fraction =
          if fraction == 0,
            do: "",
            else:
              "." <>
                (fraction
                 |> Integer.to_string()
                 |> String.pad_leading(6, "0")
                 |> String.trim_trailing("0"))

        [sign <> clock <> fraction]
      else
        []
      end

    [unit(years, "year", "years"), unit(months, "mon", "mons"), unit(days, "day", "days")]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(time)
    |> Enum.join(" ")
  end

  defp unit(0, _singular, _plural), do: nil
  defp unit(n, singular, _plural) when n in [1, -1], do: "#{n} #{singular}"
  defp unit(n, _singular, plural), do: "#{n} #{plural}"
end
