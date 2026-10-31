defmodule SentinelixWeb.MonitorComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SentinelixWeb.MonitorComponents

  defp tile(attrs) do
    attrs = Map.merge(%{id: "tile", monitor: %{id: 7, name: "Web"}, status: :up}, attrs)

    render_component(&MonitorComponents.monitor_tile/1, attrs)
    |> LazyHTML.from_fragment()
  end

  defp text(html, selector), do: html |> LazyHTML.query(selector) |> LazyHTML.text()

  describe "monitor_tile/1" do
    test "a small tile: the name, the status for screen readers, details as a tooltip" do
      html =
        tile(%{
          status: :down,
          response_time_ms: 503,
          uptime: 99.5,
          warning: true,
          maintenance: [%{title: "Upgrade"}]
        })

      [link] = LazyHTML.query(html, "a#tile") |> Enum.to_list()
      assert LazyHTML.attribute(link, "href") == ["/monitors/7"]
      assert LazyHTML.attribute(link, "data-status") == ["down"]
      assert LazyHTML.attribute(link, "aria-describedby") == ["tile-details"]
      assert text(html, "a#tile .sr-only") == ", Down"
      assert html |> LazyHTML.query("a#tile .hero-x-circle-mini") |> Enum.count() == 2

      details = text(html, "#tile-details[role=tooltip]")
      assert details =~ "Response time: 503 ms"
      assert details =~ "Uptime (24h): 99.50%"
      assert details =~ "Warning"
      assert details =~ "In maintenance: Upgrade"
    end

    test "a large tile shows the status, response time and uptime" do
      html = tile(%{size: "lg", response_time_ms: 42, navigate: "/wall/7"})

      assert html |> LazyHTML.query("a#tile[href='/wall/7']") |> Enum.count() == 1
      assert html |> LazyHTML.query("a#tile .sr-only") |> Enum.count() == 0
      assert html |> LazyHTML.query("a#tile .size-6") |> Enum.count() == 1
      visible = html |> LazyHTML.query("a#tile > span:nth-child(2)") |> LazyHTML.text()
      assert visible =~ "Up"
      assert visible =~ "42 ms"
      assert visible =~ "–"
    end
  end

  test "every status has an icon" do
    for status <- ~w(up down unreachable pending maintenance paused)a do
      refute MonitorComponents.status_icon_name(status) == "hero-question-mark-circle-mini"
    end
  end
end
