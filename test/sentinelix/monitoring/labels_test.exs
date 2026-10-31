defmodule Sentinelix.Monitoring.LabelsTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Monitoring.Labels

  doctest Labels

  describe "cast/1" do
    test "casts maps with string or atom keys" do
      assert Labels.cast(%{"Env" => " prod ", "legacy" => nil}) ==
               {:ok, %{"env" => "prod", "legacy" => ""}}

      assert Labels.cast(%{site: "oslo", host: :db1}) ==
               {:ok, %{"site" => "oslo", "host" => "db1"}}

      assert Labels.cast(nil) == {:ok, %{}}
    end

    test "casts lists of strings, tuples and form rows" do
      assert Labels.cast(["env=prod", " legacy ", "", "url=a=b"]) ==
               {:error, message: ~s(invalid value "a=b" for label url)}

      assert Labels.cast(["env=prod", " legacy ", ""]) ==
               {:ok, %{"env" => "prod", "legacy" => ""}}

      assert Labels.cast([{"env", "prod"}, {"port", 5432}]) ==
               {:ok, %{"env" => "prod", "port" => "5432"}}

      rows = [
        %{"key" => "env", "value" => "prod"},
        %{"key" => " ", "value" => ""},
        %{"key" => "site", "value" => "Helsinki"}
      ]

      assert Labels.cast(rows) == {:ok, %{"env" => "prod", "site" => "Helsinki"}}
    end

    test "keeps the case of values" do
      assert Labels.cast(["Site=Helsinki"]) == {:ok, %{"site" => "Helsinki"}}
    end

    test "rejects duplicate keys, also after normalizing" do
      assert Labels.cast(["env=prod", "env=dev"]) == {:error, message: "duplicate label key env"}

      assert {:error, message: "duplicate label key env"} =
               Labels.cast(%{"env" => "a", "ENV" => "b"})
    end

    test "rejects invalid keys and values" do
      assert Labels.cast(["web server"]) == {:error, message: ~s(invalid label key "web server")}
      assert Labels.cast(["-env=prod"]) == {:error, message: ~s(invalid label key "-env")}
      assert Labels.cast(["=prod"]) == {:error, message: ~s(label "prod" has no key)}

      assert Labels.cast([%{"key" => "", "value" => "prod"}]) ==
               {:error, message: ~s(label "prod" has no key)}

      assert Labels.cast(["env=a b"]) == {:error, message: ~s(invalid value "a b" for label env)}

      assert Labels.cast(["env=(prod)"]) ==
               {:error, message: ~s|invalid value "(prod)" for label env|}

      assert {:error, message: "invalid label " <> _} =
               Labels.cast([%{"key" => "env", "value" => %{}}])

      assert Labels.cast("env=prod") == :error
    end

    test "limits the length of keys and values and the number of labels" do
      key = String.duplicate("k", 63)
      value = String.duplicate("v", 255)
      assert {:ok, _labels} = Labels.cast(%{key => value})
      assert {:error, _} = Labels.cast(%{(key <> "k") => ""})
      assert {:error, _} = Labels.cast(%{"k" => value <> "v"})

      assert {:ok, _labels} = Labels.cast(Enum.map(1..64, &"label#{&1}"))

      assert Labels.cast(Enum.map(1..65, &"label#{&1}")) ==
               {:error, message: "at most 64 labels are allowed"}
    end

    test "accepts the characters of hosts, paths and addresses" do
      labels = ["host=db-1.example.com", "ip=2001:db8::1", "team/owner=ops@example.com", "a_b.c"]

      assert Labels.cast(labels) ==
               {:ok,
                %{
                  "host" => "db-1.example.com",
                  "ip" => "2001:db8::1",
                  "team/owner" => "ops@example.com",
                  "a_b.c" => ""
                }}
    end
  end

  test "has?/2 matches a label, or any value of a key for a label without a value" do
    labels = %{"env" => "prod", "legacy" => ""}

    assert Labels.has?(labels, {"env", "prod"})
    refute Labels.has?(labels, {"env", "dev"})
    assert Labels.has?(labels, {"env", ""})
    assert Labels.has?(labels, {"legacy", ""})
    refute Labels.has?(labels, {"site", ""})
  end

  test "to_list/1 and format/1 sort by key" do
    labels = %{"site" => "oslo", "env" => "prod", "legacy" => ""}

    assert Labels.to_list(labels) == [{"env", "prod"}, {"legacy", ""}, {"site", "oslo"}]
    assert Labels.format(labels) == ["env=prod", "legacy", "site=oslo"]
    assert Labels.format(nil) == []
  end
end
