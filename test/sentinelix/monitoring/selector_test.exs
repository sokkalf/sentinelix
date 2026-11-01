defmodule Sentinelix.Monitoring.SelectorTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring.{Monitor, Selector}
  alias Sentinelix.Monitoring.Selector.{Error, Term}
  alias Sentinelix.Repo

  doctest Selector

  defp terms(text), do: Selector.parse!(text).terms

  defp error(text, opts \\ []) do
    {:error, %Error{} = error} = Selector.parse(text, opts)
    {error.reason, error.position}
  end

  describe "parse/2" do
    test "parses every kind of term" do
      assert terms("env=prod, site in (oslo,helsinki), service!=legacy, !deprecated, host") == [
               %Term{key: "env", op: :eq, values: ["prod"]},
               %Term{key: "site", op: :in, values: ["oslo", "helsinki"]},
               %Term{key: "service", op: :neq, values: ["legacy"]},
               %Term{key: "deprecated", op: :absent},
               %Term{key: "host", op: :exists}
             ]

      assert terms("tier notin (db), host~example, host!~.org, env==prod") == [
               %Term{key: "tier", op: :notin, values: ["db"]},
               %Term{key: "host", op: :contains, values: ["example"]},
               %Term{key: "host", op: :not_contains, values: [".org"]},
               %Term{key: "env", op: :eq, values: ["prod"]}
             ]
    end

    test "an empty selector has no terms" do
      assert Selector.parse("") == {:ok, %Selector{}}
      assert Selector.parse("  ") == {:ok, %Selector{}}
      assert Selector.empty?(Selector.parse!(""))
    end

    test "ignores whitespace, lowercases keys and keeps the case of values" do
      assert terms("  Env = Prod ,site  in(  a , b ) ,! legacy ") == [
               %Term{key: "env", op: :eq, values: ["Prod"]},
               %Term{key: "site", op: :in, values: ["a", "b"]},
               %Term{key: "legacy", op: :absent}
             ]
    end

    test "drops duplicate terms and values" do
      assert terms("env=prod, env=prod, site in (a, a, b)") == [
               %Term{key: "env", op: :eq, values: ["prod"]},
               %Term{key: "site", op: :in, values: ["a", "b"]}
             ]
    end

    test "accepts label values with all their characters" do
      assert terms("url=a.b/c:d@e_f-g") == [%Term{key: "url", op: :eq, values: ["a.b/c:d@e_f-g"]}]
      assert terms("k8s.io/app=web") == [%Term{key: "k8s.io/app", op: :eq, values: ["web"]}]
    end

    test "parses the status and name pseudo-labels" do
      assert terms("status=Down, status in (up,paused), status notin (maintenance)") == [
               %Term{key: "status", op: :eq, values: ["down"]},
               %Term{key: "status", op: :in, values: ["up", "paused"]},
               %Term{key: "status", op: :notin, values: ["maintenance"]}
             ]

      assert terms(~s{name~"web #1", name="A \\"quoted\\" \\\\ name", name in (Web, "Db 2")}) == [
               %Term{key: "name", op: :contains, values: ["web #1"]},
               %Term{key: "name", op: :eq, values: [~s(A "quoted" \\ name)]},
               %Term{key: "name", op: :in, values: ["Web", "Db 2"]}
             ]
    end

    test "reports the position and what was expected" do
      assert error("env=") == {"expected a value", 4}
      assert error("env=prod,") == {"expected a label key", 9}
      assert error(", env") == {"expected a label key", 0}
      assert error("env prod") == {~s(expected "," or the end of the selector), 4}
      assert error("env=prod site=oslo") == {~s(expected "," or the end of the selector), 9}
      assert error("site in oslo") == {~s{expected "("}, 8}
      assert error("site in") == {~s{expected "("}, 7}
      assert error("site in (a b)") == {~s{expected "," or ")"}, 11}
      assert error("site in (a,") == {"expected a value", 11}
      assert error("site in ()") == {"expected a value", 9}
      assert error("!") == {"expected a label key", 1}
      assert error("env=a=b") == {~s(expected "," or the end of the selector), 5}
      assert error(~s(name~"web)) == {"unterminated quoted value", 5}
      assert error(~s(name="")) == {"expected a value", 5}
      assert error("_env") == {"expected a label key", 0}
      assert error("env=\"a b\"") == {~s(invalid label value "a b"), 4}
      assert error(String.duplicate("k", 64)) == {"label key is too long", 0}
    end

    test "checks how pseudo-labels are used" do
      assert error("status=broken") ==
               {~s(unknown status "broken", expected one of up, down, pending, maintenance, unreachable, warning, paused),
                7}

      assert error("env=prod, status in (up, nope)") ==
               {~s(unknown status "nope", expected one of up, down, pending, maintenance, unreachable, warning, paused),
                25}

      assert error("status") == {"status takes =, !=, in or notin", 0}
      assert error("env=prod, status~up") == {"status takes =, !=, in or notin", 10}
      assert error("!name") == {"name takes =, !=, ~, !~, in or notin", 0}
      assert error("name") == {"name takes =, !=, ~, !~, in or notin", 0}
    end

    test "refuses kinds of terms that aren't allowed" do
      assert error("env=prod, status=down", allow: [:labels, :name]) ==
               {"status can't be used here", 10}

      assert error("name~web", allow: [:labels]) == {"name can't be used here", 0}
      assert {:ok, _selector} = Selector.parse("env=prod, name~web", allow: [:labels, :name])

      assert_raise ArgumentError, fn -> Selector.parse("env", allow: [:tags]) end
    end

    test "counts positions in characters" do
      assert error(~s(name~"æøå", env=)) == {"expected a value", 16}
    end

    test "refuses selectors that are too long" do
      assert {:error, %Error{position: nil}} = Selector.parse(String.duplicate("a,", 1001))
    end
  end

  describe "parse!/2" do
    test "raises the error" do
      assert_raise Error, "expected a value at column 5", fn -> Selector.parse!("env=") end
    end
  end

  describe "validate/2" do
    test "validates strings and structs" do
      selector = Selector.parse!("status=down, env=prod")
      assert Selector.validate(selector) == {:ok, selector}
      assert Selector.validate("env=prod", allow: [:labels]) == Selector.parse("env=prod")

      assert {:error, %Error{reason: "status can't be used here", position: nil}} =
               Selector.validate(selector, allow: [:labels])
    end
  end

  describe "validate_selector/3" do
    defp changeset(selector) do
      Ecto.Changeset.cast({%{}, %{selector: :string}}, %{selector: selector}, [:selector],
        empty_values: []
      )
    end

    test "normalizes a valid selector" do
      changeset = changeset(" Env = prod,site in(a,b) ") |> Selector.validate_selector(:selector)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :selector) == "env=prod, site in (a, b)"
    end

    test "adds the parse error" do
      changeset =
        changeset("env=prod, status=down")
        |> Selector.validate_selector(:selector, allow: [:labels])

      assert errors_on(changeset) == %{selector: ["status can't be used here at column 11"]}
    end
  end

  describe "to_string/1" do
    test "writes the normalized form" do
      assert to_string(Selector.parse!("env = prod,!legacy,host,site notin(a,b),x!~y")) ==
               "env=prod, !legacy, host, site notin (a, b), x!~y"
    end

    test "quotes values only where needed" do
      selector = Selector.parse!(~s{name="web 1", name~a\\b, name!="x\\"y", name in ("a,b", c)})

      assert to_string(selector) ==
               ~s{name="web 1", name~a\\b, name!="x\\"y", name in ("a,b", c)}
    end
  end

  describe "building" do
    test "adds, deletes and finds terms" do
      selector = Selector.parse!("env=prod")
      selector = Selector.add(selector, Selector.label_term({"legacy", ""}))
      selector = Selector.add(selector, Selector.label_term({"env", "prod"}))
      selector = Selector.add(selector, Selector.status_term(:down))
      selector = Selector.add(selector, Selector.name_term("web 1"))

      assert to_string(selector) == ~s(env=prod, legacy, status=down, name~"web 1")
      assert Selector.member?(selector, Selector.status_term("down"))
      assert Selector.uses?(selector, :status)
      assert Selector.uses?(selector, :name)

      assert to_string(Selector.delete(selector, Selector.label_term({"env", "prod"}))) ==
               ~s(legacy, status=down, name~"web 1")

      assert to_string(Selector.delete_key(selector, "status")) ==
               ~s(env=prod, legacy, name~"web 1")

      refute Selector.uses?(Selector.delete_key(selector, "status"), :status)
    end

    test "split_status/1 separates the status terms" do
      {rest, status} = Selector.split_status(Selector.parse!("env=prod, status=down, name~a"))
      assert to_string(rest) == "env=prod, name~a"
      assert to_string(status) == "status=down"
    end
  end

  describe "matches?/3" do
    setup do
      monitor = %Monitor{
        name: "Web 1",
        labels: %{"env" => "prod", "legacy" => ""},
        auto_labels: %{"type" => "http", "host" => "example.com"},
        all_labels: %{"env" => "prod", "legacy" => "", "type" => "http", "host" => "example.com"}
      }

      %{monitor: monitor}
    end

    defp matches?(text, monitor, opts \\ []),
      do: Selector.matches?(Selector.parse!(text), monitor, opts)

    test "matches label terms on user and automatic labels", %{monitor: monitor} do
      assert matches?("", monitor)
      assert matches?("env=prod, type=http, legacy, !deprecated", monitor)
      assert matches?("env in (dev, prod), site notin (oslo), site!=oslo", monitor)
      assert matches?("host~EXAMPLE, host!~.org, site!~x", monitor)
      refute matches?("env=Prod", monitor)
      refute matches?("env!=prod", monitor)
      refute matches?("env notin (prod)", monitor)
      refute matches?("!legacy", monitor)
      refute matches?("site", monitor)
      refute matches?("site~o", monitor)
      refute matches?("site in (oslo)", monitor)
    end

    test "uses labels and automatic labels of unsaved monitors", %{monitor: monitor} do
      monitor = %{monitor | all_labels: nil}
      assert matches?("env=prod, type=http", monitor)
    end

    test "matches names", %{monitor: monitor} do
      assert matches?(~s(name~web, name~"B 1", name="Web 1", name!=web), monitor)
      assert matches?(~s{name in ("Web 1", x), name notin ("web 1"), name!~db}, monitor)
      refute matches?("name~db", monitor)
      refute matches?("name=web", monitor)
    end

    test "matches the given status", %{monitor: monitor} do
      assert matches?("status=down", monitor, status: :down)
      assert matches?("status in (up, down)", monitor, status: "down")
      assert matches?("status!=up", monitor, status: fn %Monitor{} -> :down end)
      refute matches?("status=up, env=prod", monitor, status: :down)
      refute matches?("status notin (down)", monitor, status: :down)

      assert_raise ArgumentError, ~r/:status option/, fn -> matches?("status=up", monitor) end
    end
  end

  describe "filter/2" do
    test "refuses status terms" do
      assert_raise ArgumentError, ~r/split_status/, fn ->
        Selector.filter(Monitor, Selector.parse!("env=prod, status=down"))
      end
    end

    test "escapes LIKE wildcards in ~ terms" do
      percent = monitor_fixture(:http, %{name: "100% up"})
      under = monitor_fixture(:http, %{name: "a_b"})
      _other = monitor_fixture(:http, %{name: "100 up, aXb"})

      assert query_ids("name~\"0% \"") == [percent.id]
      assert query_ids("name~a_b") == [under.id]
      assert query_ids("name~_") == [under.id]
    end
  end

  # The database and the in-memory evaluator give the same answer, on
  # selectors generated (deterministically) from a pool of keys, values and
  # names chosen to hit the edge cases: missing keys, labels without a
  # value, case differences, substrings, LIKE wildcards. (Names are ASCII:
  # how ILIKE folds the case of other letters depends on the database's
  # locale.)
  describe "evaluators" do
    @keys ["env", "site", "tier", "legacy", "type", "host", "k8s.io/app", "missing"]
    @values ["prod", "Prod", "pro", "dev", "oslo", "o", "a_b", "a.b", "db.example.com", "http"]
    @names ["Web 1", "web 10", "Database", "100% up", "a_b", "AXB", "x\\y"]

    setup do
      label_sets = [
        %{},
        %{"env" => "prod"},
        %{"env" => "Prod", "site" => "oslo"},
        %{"env" => "dev", "legacy" => ""},
        %{"env" => "pro", "tier" => "a_b", "site" => "o"},
        %{"legacy" => "", "tier" => "a.b", "k8s.io/app" => "http"},
        %{"site" => "oslo", "tier" => "aXb"}
      ]

      monitors =
        for {labels, i} <- Enum.with_index(label_sets),
            {type, j} <- Enum.with_index([:http, :tcp, :push]) do
          name = Enum.at(@names, rem(i * 3 + j, length(@names)))
          monitor_fixture(type, %{name: name, labels: labels})
        end

      %{monitors: monitors}
    end

    test "agree on generated selectors", %{monitors: monitors} do
      :rand.seed(:exsss, {38, 38, 38})

      for _run <- 1..300 do
        selector = %Selector{terms: for(_ <- 1..Enum.random(1..3), do: random_term())}

        # Selectors survive a round trip through their string form.
        assert Selector.parse!(to_string(selector)) == %{
                 selector
                 | terms: Enum.uniq(selector.terms)
               }

        expected =
          monitors
          |> Enum.filter(&Selector.matches?(selector, &1))
          |> Enum.map(& &1.id)
          |> Enum.sort()

        assert query_ids(selector) == expected, "selector: #{selector}"
      end
    end

    defp random_term do
      key = if :rand.uniform(5) == 1, do: "name", else: Enum.random(@keys)
      values = if key == "name", do: @names ++ ["web", "0%", "_", "\\", "b 1"], else: @values

      case Enum.random([:exists, :absent, :eq, :neq, :contains, :not_contains, :in, :notin]) do
        op when op in [:exists, :absent] and key == "name" ->
          %Term{key: key, op: :contains, values: ["e"]}

        op when op in [:exists, :absent] ->
          %Term{key: key, op: op}

        op when op in [:in, :notin] ->
          %Term{key: key, op: op, values: Enum.take_random(values, Enum.random(1..3))}

        op ->
          %Term{key: key, op: op, values: [Enum.random(values)]}
      end
    end
  end

  defp query_ids(%Selector{} = selector) do
    Monitor |> Selector.filter(selector) |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp query_ids(text), do: query_ids(Selector.parse!(text))
end
