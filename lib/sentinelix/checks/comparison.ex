defmodule Sentinelix.Checks.Comparison do
  @moduledoc """
  Comparisons of a value (as text) with an expected value, shared by the
  checks that assert on what they receive (e.g. the value of a PostgreSQL
  query in `Sentinelix.Checks.Postgres.Expectation` and the response
  assertions of `Sentinelix.Checks.HTTP`), so behaviour and messages are the
  same everywhere.

  Comparisons (`comparisons/0`):

    * `equals`, `not_equals` – exact text comparison.
    * `contains`, `not_contains` – whether the text contains the expected
      value.
    * `regex`, `not_regex` – whether the text matches the regular
      expression. The pattern is matched with Unicode semantics when the text
      is valid UTF-8 and byte-wise otherwise.
    * `<`, `<=`, `>`, `>=` – numeric: both sides are parsed as decimal
      numbers (`parse_number/1`); a value that isn't a (finite) number fails.
    * `exists`, `not_exists` – whether there is a value at all (`nil` means
      there isn't); the expected value is ignored.

  With `case_sensitive: false` the text comparisons ignore case
  (`String.downcase/1` on both sides, the `i` flag for regular expressions).
  """

  @comparisons ~w(equals not_equals contains not_contains regex not_regex < <= > >= exists not_exists)
  @numeric ~w(< <= > >=)
  @regex ~w(regex not_regex)
  @presence ~w(exists not_exists)
  @max_shown 100

  @type comparison :: String.t()

  @doc "All comparisons."
  @spec comparisons() :: [comparison()]
  def comparisons, do: @comparisons

  @doc "Whether a comparison is numeric (`<`, `<=`, `>`, `>=`)."
  @spec numeric?(comparison()) :: boolean()
  def numeric?(comparison), do: comparison in @numeric

  @doc "Whether a comparison is a regular expression match."
  @spec regex?(comparison()) :: boolean()
  def regex?(comparison), do: comparison in @regex

  @doc "Whether a comparison only checks for the presence of a value."
  @spec presence?(comparison()) :: boolean()
  def presence?(comparison), do: comparison in @presence

  @doc """
  Compares a value (as text, or `nil` when there is none) with the expected
  value.

  Returns `:ok` or `{:error, reason}`, where `reason` is a suffix for the
  failure message: `""`, `" (not a number)"` or `" (invalid regular
  expression)"`. Only `exists`/`not_exists` accept a missing value, every
  other comparison fails on it.

  Options: `case_sensitive` (default `true`).
  """
  @spec compare(String.t() | nil, comparison(), String.t() | nil, keyword()) ::
          :ok | {:error, String.t()}
  def compare(actual, comparison, expected, opts \\ [])

  def compare(actual, "exists", _expected, _opts), do: result(not is_nil(actual))
  def compare(actual, "not_exists", _expected, _opts), do: result(is_nil(actual))
  def compare(nil, _comparison, _expected, _opts), do: {:error, ""}

  def compare(actual, comparison, expected, _opts) when comparison in @numeric do
    with {:ok, actual} <- parse_number(actual),
         {:ok, expected} <- parse_number(expected || "") do
      result(compare_numbers(Decimal.compare(actual, expected), comparison))
    else
      :error -> {:error, " (not a number)"}
    end
  end

  def compare(actual, comparison, expected, opts) when comparison in @regex do
    case compile_regex(expected || "", case_sensitive?(opts), String.valid?(actual)) do
      {:ok, regex} -> result(Regex.match?(regex, actual) == (comparison == "regex"))
      :error -> {:error, " (invalid regular expression)"}
    end
  end

  def compare(actual, comparison, expected, opts) do
    {actual, expected} = normalize_case(actual, expected || "", case_sensitive?(opts))

    result(
      case comparison do
        "equals" -> actual == expected
        "not_equals" -> actual != expected
        "contains" -> String.contains?(actual, expected)
        "not_contains" -> not String.contains?(actual, expected)
      end
    )
  end

  defp result(true), do: :ok
  defp result(false), do: {:error, ""}

  defp case_sensitive?(opts), do: Keyword.get(opts, :case_sensitive, true) != false

  defp normalize_case(actual, expected, true), do: {actual, expected}

  defp normalize_case(actual, expected, false),
    do: {downcase(actual), String.downcase(expected)}

  # `String.downcase/1` works on code points; leave text that isn't UTF-8
  # alone apart from ASCII letters.
  defp downcase(text) do
    if String.valid?(text),
      do: String.downcase(text),
      else: for(<<byte <- text>>, into: "", do: <<ascii_downcase(byte)>>)
  end

  defp ascii_downcase(byte) when byte in ?A..?Z, do: byte + 32
  defp ascii_downcase(byte), do: byte

  defp compare_numbers(order, "<"), do: order == :lt
  defp compare_numbers(order, "<="), do: order in [:lt, :eq]
  defp compare_numbers(order, ">"), do: order == :gt
  defp compare_numbers(order, ">="), do: order in [:gt, :eq]

  @doc """
  Compiles a regular expression pattern, case-insensitively unless
  `case_sensitive?`, and with Unicode semantics when `unicode?`.
  """
  @spec compile_regex(String.t(), boolean(), boolean()) :: {:ok, Regex.t()} | :error
  def compile_regex(pattern, case_sensitive? \\ true, unicode? \\ true) do
    flags = if(unicode?, do: "u", else: "") <> if(case_sensitive?, do: "", else: "i")

    case Regex.compile(pattern, flags) do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> :error
    end
  end

  @doc "Whether `pattern` is a valid regular expression."
  @spec valid_regex?(String.t()) :: boolean()
  def valid_regex?(pattern), do: match?({:ok, _}, compile_regex(pattern))

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

  @doc """
  Describes what a comparison expected, for failure messages, e.g.
  `expected it to contain "OK"` or `expected < 100`.
  """
  @spec describe(comparison(), term()) :: String.t()
  def describe("equals", expected), do: ~s(expected "#{truncate(expected)}")
  def describe("not_equals", expected), do: ~s(expected anything but "#{truncate(expected)}")
  def describe("contains", expected), do: ~s(expected it to contain "#{truncate(expected)}")

  def describe("not_contains", expected),
    do: ~s(expected it not to contain "#{truncate(expected)}")

  def describe("regex", expected), do: "expected it to match /#{truncate(expected)}/"
  def describe("not_regex", expected), do: "expected it not to match /#{truncate(expected)}/"
  def describe("exists", _expected), do: "expected it to exist"
  def describe("not_exists", _expected), do: "expected it not to exist"
  def describe(operator, expected), do: "expected #{operator} #{expected}"

  @doc """
  Shortens text for messages to #{@max_shown} characters (followed by `…`).
  Text that isn't valid UTF-8 is shown as `<binary, N bytes>`.
  """
  @spec truncate(term()) :: String.t()
  def truncate(nil), do: ""
  def truncate(text) when not is_binary(text), do: truncate(to_string(text))

  def truncate(text) do
    cond do
      not String.valid?(text) -> "<binary, #{byte_size(text)} bytes>"
      String.length(text) > @max_shown -> String.slice(text, 0, @max_shown) <> "…"
      true -> text
    end
  end
end
