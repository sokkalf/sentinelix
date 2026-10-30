defmodule Sentinelix.StatusPagesFixtures do
  @moduledoc """
  Test helpers for creating status pages via the `Sentinelix.StatusPages`
  context.
  """

  alias Sentinelix.StatusPages

  def status_page_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, page} =
      attrs
      |> Enum.into(%{title: "Status #{n}", slug: "status-#{n}"})
      |> StatusPages.create_status_page()

    page
  end

  def group_fixture(page, attrs \\ %{}) do
    {:ok, group} = StatusPages.create_group(page, Enum.into(attrs, %{name: "Services"}))
    group
  end

  @doc """
  A published page with one group containing the given monitors (in order).
  """
  def published_page_fixture(monitors, attrs \\ %{}) do
    page = status_page_fixture(Enum.into(attrs, %{published: true}))
    group = group_fixture(page)
    Enum.each(monitors, &({:ok, _} = StatusPages.add_monitor(group, &1)))
    page
  end
end
