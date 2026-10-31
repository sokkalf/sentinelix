defmodule Sentinelix.YAMLTest do
  use ExUnit.Case, async: true

  alias Sentinelix.YAML

  doctest Sentinelix.YAML

  @tricky_strings [
    "",
    " ",
    "plain",
    "with spaces",
    "true",
    "False",
    "yes",
    "No",
    "on",
    "null",
    "~",
    "y",
    "123",
    "0x1F",
    "1.5",
    "1e3",
    ".inf",
    ".nan",
    "-1",
    "2026-10-31",
    "@handle",
    "&anchor",
    "*alias",
    "!tag",
    "!!str",
    "%directive",
    "- dash",
    "-",
    "?",
    ": colon",
    "key: value",
    "trailing:",
    "trailing ",
    " leading",
    "a # comment",
    "#hash",
    "quote \"inside\"",
    "'single'",
    "back\\slash",
    "[list]",
    "{map}",
    "a, b",
    "https://example.com/health?x=1&y=2#frag",
    "tab\there",
    "carriage\r\nreturn",
    "line\nbreak",
    "line\nbreak\n",
    "lines\n\n\n",
    "\nleading newline",
    "  indented\nblock",
    "first\n  indented second\n",
    "spaces only\n   \nline",
    "unicode æøå 🚀",
    "nel\u0085char",
    "line\u2028separator",
    "\uFEFFbom",
    "bell\a",
    "null\0byte",
    "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
    "SELECT 1\nFROM dual"
  ]

  describe "encode/1 and decode/1" do
    test "round-trip tricky strings as values and keys" do
      for string <- @tricky_strings do
        assert {:ok, %{"value" => ^string}} = YAML.decode(YAML.encode([{"value", string}])),
               "value #{inspect(string)}: #{YAML.encode([{"value", string}])}"

        assert {:ok, %{^string => 1}} = YAML.decode(YAML.encode([{string, 1}])),
               "key #{inspect(string)}"

        assert {:ok, %{"list" => [^string, "after"]}} =
                 YAML.decode(YAML.encode([{"list", [string, "after"]}])),
               "list item #{inspect(string)}"
      end
    end

    test "round-trip nested data" do
      data = [
        {"version", 1},
        {"monitors",
         [
           [
             {"name", "API"},
             {"enabled", false},
             {"labels", %{"env" => "prod", "legacy" => ""}},
             {"codes", ["200", "300-399"]},
             {"query", "SELECT 1\nFROM t\n"},
             {"empty_map", %{}},
             {"empty_list", []}
           ],
           [{"name", "Second"}, {"nested", [[{"a", 1}, {"b", [1, 2]}]]}]
         ]}
      ]

      assert {:ok, decoded} = data |> YAML.encode() |> YAML.decode()

      assert decoded == %{
               "version" => 1,
               "monitors" => [
                 %{
                   "name" => "API",
                   "enabled" => false,
                   "labels" => %{"env" => "prod", "legacy" => ""},
                   "codes" => ["200", "300-399"],
                   "query" => "SELECT 1\nFROM t\n",
                   "empty_map" => %{},
                   "empty_list" => []
                 },
                 %{"name" => "Second", "nested" => [%{"a" => 1, "b" => [1, 2]}]}
               ]
             }
    end

    test "writes readable YAML" do
      yaml =
        YAML.encode([
          {"name", "Shop API"},
          {"url", "https://example.com/health"},
          {"labels", %{"team" => "web", "env" => "prod"}},
          {"items", [[{"a", "1"}, {"b", true}]]},
          {"pem", "line 1\nline 2\n"}
        ])

      assert yaml == """
             name: Shop API
             url: https://example.com/health
             labels:
               env: prod
               team: web
             items:
               - a: "1"
                 b: true
             pem: |
               line 1
               line 2
             """
    end

    test "refuses values it can't write" do
      assert_raise ArgumentError, fn -> YAML.encode([{"float", 1.5}]) end
      assert_raise ArgumentError, fn -> YAML.encode([{"atom", :atom}]) end
      assert_raise ArgumentError, fn -> YAML.encode([{"bytes", <<0xFF>>}]) end
    end
  end

  describe "decode/1" do
    test "rejects custom tags" do
      assert {:error, message} = YAML.decode("a: !foo bar")
      assert message =~ "line 1"
      assert {:error, _message} = YAML.decode("a: !!python/object:os.system x")
    end

    test "doesn't create atoms" do
      assert YAML.decode("a: :not_an_existing_atom_i49") ==
               {:ok, %{"a" => ":not_an_existing_atom_i49"}}

      assert {:error, _message} = YAML.decode("a: .inf")
    end

    test "rejects non-string keys, invalid UTF-8 and several documents" do
      assert {:error, message} = YAML.decode("a:\n  1: x\n")
      assert message =~ "a has a key that isn't a string"

      assert {:error, "the file is not valid UTF-8"} = YAML.decode(<<"a: ", 0xFF>>)
      assert {:error, message} = YAML.decode("a: !!binary /w==")
      assert message =~ "a is not valid UTF-8"

      assert {:error, "expected a single YAML document"} = YAML.decode("a: 1\n---\nb: 2\n")
    end

    test "reports syntax errors" do
      assert {:error, message} = YAML.decode("a: b: c")
      assert message =~ "invalid YAML at line 1"
    end

    test "an empty document is nil" do
      assert YAML.decode("") == {:ok, nil}
    end
  end
end
