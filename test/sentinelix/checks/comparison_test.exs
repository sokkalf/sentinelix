defmodule Sentinelix.Checks.ComparisonTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Checks.Comparison

  describe "compare/4" do
    test "text comparisons" do
      assert Comparison.compare("ok", "equals", "ok") == :ok
      assert {:error, _} = Comparison.compare("ok", "equals", "OK")
      assert Comparison.compare("ok", "not_equals", "fail") == :ok
      assert {:error, _} = Comparison.compare("ok", "not_equals", "ok")
      assert Comparison.compare("PostgreSQL 16.4", "contains", "16.") == :ok
      assert {:error, _} = Comparison.compare("PostgreSQL 15.8", "contains", "16.")
      assert Comparison.compare("PostgreSQL 16.4", "regex", ~S"^PostgreSQL 1[6-9]\.") == :ok
      assert {:error, _} = Comparison.compare("PostgreSQL 15.8", "regex", ~S"^PostgreSQL 16")

      assert Comparison.compare("x", "regex", "(") ==
               {:error, " (invalid regular expression)"}
    end

    test "numeric comparisons" do
      assert Comparison.compare("42", "<", "100") == :ok
      assert {:error, ""} = Comparison.compare("100", "<", "100")
      assert Comparison.compare("100", "<=", "100") == :ok
      assert {:error, ""} = Comparison.compare("100.5", "<=", "100")
      assert Comparison.compare("1e3", ">", "999.9") == :ok
      assert {:error, ""} = Comparison.compare("-1", ">", "0")
      assert Comparison.compare("0.10", ">=", "0.1") == :ok
      assert {:error, ""} = Comparison.compare("0.09", ">=", "0.1")
    end

    test "numeric comparisons fail for values that are not numbers" do
      assert Comparison.compare("abc", ">", "1") == {:error, " (not a number)"}
      assert Comparison.compare("NULL", ">", "1") == {:error, " (not a number)"}
      assert Comparison.compare("NaN", ">", "1") == {:error, " (not a number)"}
      assert Comparison.compare("Infinity", ">", "1") == {:error, " (not a number)"}
      assert Comparison.compare("1x", ">", "0") == {:error, " (not a number)"}
    end

    test "negated and presence comparisons" do
      assert Comparison.compare("all good", "not_contains", "error") == :ok
      assert {:error, ""} = Comparison.compare("an error", "not_contains", "error")
      assert Comparison.compare("healthy", "not_regex", "^un") == :ok
      assert {:error, ""} = Comparison.compare("unhealthy", "not_regex", "^un")

      assert Comparison.compare("x", "not_regex", "(") ==
               {:error, " (invalid regular expression)"}

      assert Comparison.compare("", "exists", nil) == :ok
      assert {:error, ""} = Comparison.compare(nil, "exists", nil)
      assert Comparison.compare(nil, "not_exists", nil) == :ok
      assert {:error, ""} = Comparison.compare("x", "not_exists", nil)
    end

    test "a missing value fails every other comparison" do
      for comparison <- Comparison.comparisons() -- ["exists", "not_exists"] do
        assert {:error, _} = Comparison.compare(nil, comparison, "x"), comparison
      end
    end

    test "case-insensitive comparisons" do
      opts = [case_sensitive: false]

      assert Comparison.compare("OK", "equals", "ok", opts) == :ok
      assert {:error, ""} = Comparison.compare("OK", "not_equals", "ok", opts)
      assert Comparison.compare("Status: OK", "contains", "ok", opts) == :ok
      assert {:error, ""} = Comparison.compare("ERROR", "not_contains", "error", opts)
      assert Comparison.compare("Healthy", "regex", "^healthy$", opts) == :ok
      assert {:error, ""} = Comparison.compare("Healthy", "regex", "^healthy$")
      assert Comparison.compare("ÆØÅ", "equals", "æøå", opts) == :ok
      assert Comparison.compare(<<"OK", 255>>, "contains", "ok", opts) == :ok
    end

    test "regular expressions use Unicode semantics for UTF-8 text only" do
      assert Comparison.compare("blåbær", "regex", "^\\w+$") == :ok
      assert Comparison.compare("ø", "regex", "^.$") == :ok
      assert Comparison.compare(<<0xFF, 0xFE>>, "regex", "^..$") == :ok
    end
  end

  describe "describe/2 and truncate/1" do
    test "describe what was expected" do
      assert Comparison.describe("equals", "ok") == ~s(expected "ok")
      assert Comparison.describe("not_contains", "x") == ~s(expected it not to contain "x")
      assert Comparison.describe("not_regex", "^a") == "expected it not to match /^a/"
      assert Comparison.describe("exists", nil) == "expected it to exist"
      assert Comparison.describe("<", "100") == "expected < 100"
    end

    test "truncates long and binary text" do
      assert Comparison.truncate(String.duplicate("a", 150)) == String.duplicate("a", 100) <> "…"
      assert Comparison.truncate(<<0xFF, 0xFE>>) == "<binary, 2 bytes>"
      assert Comparison.truncate(nil) == ""
    end
  end

  describe "parse_number/1" do
    test "parses finite decimals" do
      assert {:ok, decimal} = Comparison.parse_number(" 1.50 ")
      assert Decimal.equal?(decimal, Decimal.new("1.5"))
      assert Comparison.parse_number("NaN") == :error
      assert Comparison.parse_number("") == :error
    end
  end
end
