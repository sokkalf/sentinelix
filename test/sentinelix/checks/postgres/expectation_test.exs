defmodule Sentinelix.Checks.Postgres.ExpectationTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Checks.Postgres.Expectation

  defp result(rows), do: %Postgrex.Result{rows: rows, num_rows: length(rows)}

  describe "to_text/1" do
    test "converts Postgrex values" do
      assert Expectation.to_text(nil) == "NULL"
      assert Expectation.to_text(true) == "true"
      assert Expectation.to_text(false) == "false"
      assert Expectation.to_text(42) == "42"
      assert Expectation.to_text(-1.5) == "-1.5"
      assert Expectation.to_text(:NaN) == "NaN"
      assert Expectation.to_text(:inf) == "Infinity"
      assert Expectation.to_text(:"-inf") == "-Infinity"
      assert Expectation.to_text(Decimal.new("1.50")) == "1.50"
      assert Expectation.to_text(Decimal.new("1E+3")) == "1000"
      assert Expectation.to_text(~D[2026-10-30]) == "2026-10-30"
      assert Expectation.to_text(~T[12:30:00]) == "12:30:00"
      assert Expectation.to_text(~N[2026-10-30 12:30:00]) == "2026-10-30T12:30:00"
      assert Expectation.to_text(~U[2026-10-30 12:30:00.123Z]) == "2026-10-30T12:30:00.123Z"
      assert Expectation.to_text(~U[2026-10-30 12:30:00.000000Z]) == "2026-10-30T12:30:00Z"
      assert Expectation.to_text(~U[2026-10-30 12:30:00.120000Z]) == "2026-10-30T12:30:00.12Z"
      assert Expectation.to_text(~T[12:30:00.000100]) == "12:30:00.0001"
      assert Expectation.to_text("16.4 (Debian)") == "16.4 (Debian)"
      assert Expectation.to_text(<<0, 255>>) == "\\x00ff"
      assert Expectation.to_text([1, nil, "a"]) == "{1,NULL,a}"
      assert Expectation.to_text(%{"a" => 1}) == ~s({"a":1})
    end

    test "formats intervals like PostgreSQL" do
      interval = &struct!(Postgrex.Interval, &1)

      assert Expectation.to_text(interval.(months: 14, days: 3, secs: 14_706, microsecs: 0)) ==
               "1 year 2 mons 3 days 04:05:06"

      assert Expectation.to_text(interval.(months: 0, days: 1, secs: 0, microsecs: 0)) == "1 day"

      assert Expectation.to_text(interval.(months: 0, days: 0, secs: 5, microsecs: 500_000)) ==
               "00:00:05.5"

      assert Expectation.to_text(interval.(months: 0, days: 0, secs: -60, microsecs: 0)) ==
               "-00:01:00"

      assert Expectation.to_text(interval.(months: 0, days: 0, secs: 0, microsecs: 0)) ==
               "00:00:00"
    end
  end

  describe "compare/3" do
    test "text comparisons" do
      assert Expectation.compare("ok", "equals", "ok") == :ok
      assert {:error, _} = Expectation.compare("ok", "equals", "OK")
      assert Expectation.compare("ok", "not_equals", "fail") == :ok
      assert {:error, _} = Expectation.compare("ok", "not_equals", "ok")
      assert Expectation.compare("PostgreSQL 16.4", "contains", "16.") == :ok
      assert {:error, _} = Expectation.compare("PostgreSQL 15.8", "contains", "16.")
      assert Expectation.compare("PostgreSQL 16.4", "regex", ~S"^PostgreSQL 1[6-9]\.") == :ok
      assert {:error, _} = Expectation.compare("PostgreSQL 15.8", "regex", ~S"^PostgreSQL 16")

      assert Expectation.compare("x", "regex", "(") ==
               {:error, " (invalid regular expression)"}
    end

    test "numeric comparisons" do
      assert Expectation.compare("42", "<", "100") == :ok
      assert {:error, ""} = Expectation.compare("100", "<", "100")
      assert Expectation.compare("100", "<=", "100") == :ok
      assert {:error, ""} = Expectation.compare("100.5", "<=", "100")
      assert Expectation.compare("1e3", ">", "999.9") == :ok
      assert {:error, ""} = Expectation.compare("-1", ">", "0")
      assert Expectation.compare("0.10", ">=", "0.1") == :ok
      assert {:error, ""} = Expectation.compare("0.09", ">=", "0.1")
    end

    test "numeric comparisons fail for values that are not numbers" do
      assert Expectation.compare("abc", ">", "1") == {:error, " (not a number)"}
      assert Expectation.compare("NULL", ">", "1") == {:error, " (not a number)"}
      assert Expectation.compare("NaN", ">", "1") == {:error, " (not a number)"}
      assert Expectation.compare("Infinity", ">", "1") == {:error, " (not a number)"}
      assert Expectation.compare("1x", ">", "0") == {:error, " (not a number)"}
    end
  end

  describe "check_value/3" do
    test "compares the first column of the first row" do
      assert Expectation.check_value(result([[42, "x"], [1, "y"]]), nil, "equals") == :skip

      assert Expectation.check_value(result([[42, "x"], [1, "y"]]), "42", "equals") ==
               {:ok, ~s(got "42")}

      assert Expectation.check_value(result([[42]]), "100", ">") ==
               {:error, ~s(got "42", expected > 100)}

      assert Expectation.check_value(result([["a"]]), "100", ">") ==
               {:error, ~s[got "a", expected > 100 (not a number)]}

      assert Expectation.check_value(result([["15.8"]]), "16.", "contains") ==
               {:error, ~s(got "15.8", expected it to contain "16.")}

      assert Expectation.check_value(result([[true]]), "true", "not_equals") ==
               {:error, ~s(got "true", expected anything but "true")}

      assert Expectation.check_value(result([["b"]]), "^a", "regex") ==
               {:error, ~s(got "b", expected it to match /^a/)}

      assert Expectation.check_value(result([[false]]), "true", "equals") ==
               {:error, ~s(got "false", expected "true")}
    end

    test "fails without rows and truncates long values" do
      assert Expectation.check_value(result([]), "1", "equals") ==
               {:error, ~s(got no rows, expected "1")}

      long = String.duplicate("a", 150)
      assert {:ok, message} = Expectation.check_value(result([[long]]), long, "equals")
      assert message == ~s(got "#{String.duplicate("a", 100)}…")
    end
  end

  describe "check_rows/3" do
    test "compares the number of rows" do
      assert Expectation.check_rows(result([[1]]), nil, "equals") == :skip
      assert Expectation.check_rows(result([]), 0, "equals") == :ok
      assert Expectation.check_rows(result([[1], [2]]), 1, ">=") == :ok

      assert Expectation.check_rows(result([[1], [2], [3]]), 0, "<=") ==
               {:error, "got 3 rows, expected <= 0"}

      assert Expectation.check_rows(result([]), 1, ">=") == {:error, "got 0 rows, expected >= 1"}

      assert Expectation.check_rows(result([[1]]), 1, "not_equals") ==
               {:error, ~s(got 1 row, expected anything but "1")}
    end
  end
end
