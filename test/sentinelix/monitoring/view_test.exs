defmodule Sentinelix.Monitoring.ViewTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Monitoring.{Selector, View}

  doctest View

  test "the default view has no parameters" do
    assert View.from_params(%{}) == {:ok, %View{}}
    assert View.to_params(%View{}) == []
  end

  test "reads and writes selector, group-by, sort and layout" do
    params = %{
      "selector" => "env=prod, status=down",
      "group" => "service,site",
      "sort" => "name",
      "layout" => "grid"
    }

    assert {:ok, view} = View.from_params(params)
    assert view.selector == Selector.parse!("env=prod, status=down")
    assert view.group_by == ["service", "site"]
    assert view.sort == :name
    assert view.layout == :grid
    assert View.grouped?(view)

    assert View.to_params(view) == [
             selector: "env=prod, status=down",
             group: "service,site",
             sort: "name",
             layout: "grid"
           ]

    assert View.from_params(Map.new(View.to_params(view), fn {k, v} -> {to_string(k), v} end)) ==
             {:ok, view}
  end

  test "reads and writes the layout" do
    for layout <- [:grid, :matrix] do
      params = %{"group" => "service,site", "layout" => Atom.to_string(layout)}
      assert {:ok, %View{layout: ^layout} = view} = View.from_params(params)
      assert View.to_params(view) == [group: "service,site", layout: Atom.to_string(layout)]
    end

    assert {:ok, %View{layout: :list}} = View.from_params(%{"layout" => "list"})
    assert View.to_params(%View{layout: :list}) == []
    assert View.to_params(%View{layout: :grid}) == [layout: "grid"]

    # Unknown layouts and parameters that aren't text are the default.
    assert {:ok, %View{layout: :list}} = View.from_params(%{"layout" => "table"})
    assert {:ok, %View{layout: :list}} = View.from_params(%{"layout" => ["grid"]})
  end

  test "a matrix needs two group-by keys" do
    assert View.matrix?(%View{layout: :matrix, group_by: ["service", "site"]})
    refute View.matrix?(%View{layout: :matrix, group_by: ["service"]})
    refute View.matrix?(%View{layout: :matrix})
    refute View.matrix?(%View{layout: :grid, group_by: ["service", "site"]})
  end

  test "leaves out the sort when not grouping" do
    assert View.to_params(%View{sort: :name}) == []
  end

  test "ignores invalid group-by keys and sorts" do
    assert {:ok, view} =
             View.from_params(%{
               "group" => " Site ,status,name,-bad,site,env,team",
               "sort" => "x"
             })

    assert view.group_by == ["site", "env"]
    assert view.sort == :problems

    assert View.group_by_param(["env", "", "site"]) == ["env", "site"]
    assert View.group_by_param(%{"a" => "b"}) == []

    # Lists, as the dashboard's form sends them.
    assert {:ok, %View{group_by: ["x"], sort: :problems}} =
             View.from_params(%{"group" => ["x", 1], "sort" => ["name"]})
  end

  test "an invalid selector keeps the rest of the view" do
    assert {:error, view, "env=", %Selector.Error{}} =
             View.from_params(%{"selector" => "env=", "group" => "site"})

    assert view.selector == nil
    assert view.group_by == ["site"]
    assert View.to_params(view) == [group: "site"]
  end

  test "translates the parameters of older links" do
    assert {:ok, view} =
             View.from_params(%{"q" => " web ", "status" => "down", "tag" => "legacy"})

    assert Selector.to_string(view.selector) == "name~web, status=down, legacy"

    assert {:ok, view} = View.from_params(%{"label" => "env=prod", "status" => "bogus"})
    assert Selector.to_string(view.selector) == "env=prod"
  end
end
