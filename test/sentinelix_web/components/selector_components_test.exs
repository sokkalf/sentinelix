defmodule SentinelixWeb.SelectorComponentsTest do
  use ExUnit.Case, async: true

  alias SentinelixWeb.SelectorComponents

  doctest SelectorComponents

  @values SelectorComponents.completion_values(%{
            "env" => ["dev", "prod"],
            "legacy" => [""],
            "site" => ["oslo"],
            "status" => ["shadowed"]
          })

  defp suggestions(text), do: SelectorComponents.suggestions(text, @values)

  describe "suggestions/2" do
    test "completes keys, with their values" do
      assert suggestions("") == [
               "env",
               "env=dev",
               "env=prod",
               "legacy",
               "name~",
               "site",
               "site=oslo",
               "status=up",
               "status=down",
               "status=pending",
               "status=maintenance",
               "status=unreachable",
               "status=warning",
               "status=paused"
             ]

      assert suggestions("E") == ["env", "env=dev", "env=prod"]

      assert suggestions("env=prod,  s") ==
               ["env=prod,  site", "env=prod,  site=oslo"] ++
                 Enum.map(
                   ~w(up down pending maintenance unreachable warning paused),
                   &"env=prod,  status=#{&1}"
                 )
    end

    test "completes values after an operator" do
      assert suggestions("env!=") == ["env!=dev", "env!=prod"]
      assert suggestions("env = d") == ["env=dev"]
      assert suggestions("status in (up), status!=m") == ["status in (up), status!=maintenance"]
      assert suggestions("site=x, env=x") |> hd() == "site=x, env=x, env"
    end

    test "suggests the next term when nothing is left to complete" do
      assert ["env=prod, env", "env=prod, env=dev" | _rest] = suggestions("env=prod")
      assert ["legacy, env" | _rest] = suggestions("legacy")
      assert suggestions("env=prod, site=") == ["env=prod, site=oslo"]
      assert suggestions("env=prod, site=x y") == []
    end

    test "completes absent keys, not pseudo-labels" do
      assert suggestions("!") == ["!env", "!legacy", "!site"]
    end

    test "completes values in lists" do
      assert suggestions("env in (") == ["env in (dev", "env in (prod"]
      assert suggestions("env notin (dev, p") == ["env notin (dev, prod"]
      assert suggestions("env in (dev), site in (o") == ["env in (dev), site in (oslo"]
      assert suggestions("env in (dev) ") |> hd() == "env in (dev), env"
    end

    test "ignores separators in quoted values" do
      assert suggestions(~s{name~"a, (b", e}) == [
               ~s{name~"a, (b", env},
               ~s{name~"a, (b", env=dev},
               ~s{name~"a, (b", env=prod}
             ]
    end
  end

  test "label_values/1 collects the labels of monitors" do
    monitors = [
      %{all_labels: %{"env" => "prod", "type" => "http"}},
      %{all_labels: %{"env" => "dev", "type" => "http"}},
      %{all_labels: nil}
    ]

    assert SelectorComponents.label_values(monitors) == %{
             "env" => ["dev", "prod"],
             "type" => ["http"]
           }
  end
end
