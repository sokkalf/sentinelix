Code.require_file(
  "../../../priv/repo/migrations/20261101150000_fold_keyword_monitors_into_http.exs",
  __DIR__
)

defmodule Sentinelix.Migrations.FoldKeywordMonitorsTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.Settings.Assertion
  alias Sentinelix.Repo
  alias Sentinelix.Repo.Migrations.FoldKeywordMonitorsIntoHttp

  # A monitor as the keyword type stored it before the migration.
  defp keyword_monitor(settings) do
    monitor = monitor_fixture(:http)

    Repo.query!(
      """
      UPDATE monitors
         SET type = 'keyword', settings = $2, auto_labels = auto_labels || '{"type": "keyword"}'
       WHERE id = $1
      """,
      [monitor.id, Map.merge(%{"url" => "https://example.com", "method" => "GET"}, settings)]
    )

    monitor
  end

  defp migrate!(monitor) do
    Repo.query!(FoldKeywordMonitorsIntoHttp.sql())
    Monitoring.get_monitor!(monitor.id)
  end

  @cases [
    {%{"keyword" => "OK"},
     %Assertion{source: "body", comparison: "contains", value: "OK", case_sensitive: true}},
    {%{"keyword" => "error", "invert_keyword" => true, "case_sensitive" => false},
     %Assertion{source: "body", comparison: "not_contains", value: "error", case_sensitive: false}},
    {%{"keyword" => "UP", "json_path" => "data.status", "invert_keyword" => false},
     %Assertion{source: "json", path: "data.status", comparison: "equals", value: "UP"}},
    {%{"keyword" => "DOWN", "json_path" => "status", "invert_keyword" => true},
     %Assertion{source: "json", path: "status", comparison: "not_equals", value: "DOWN"}}
  ]

  test "keyword monitors become http monitors with an equivalent assertion" do
    monitors = for {settings, expected} <- @cases, do: {keyword_monitor(settings), expected}

    for {monitor, expected} <- monitors do
      monitor = migrate!(monitor)

      assert monitor.type == :http
      assert monitor.auto_labels["type"] == "http"
      assert monitor.all_labels["type"] == "http"
      assert monitor.settings.url == "https://example.com"
      assert monitor.settings.assertions == [expected]

      # The result is valid as it is.
      assert Monitoring.change_monitor(monitor, %{}).valid?
    end
  end

  test "converts like the import of keyword monitors" do
    for {settings, expected} <- @cases do
      assert Assertion.from_keyword(settings) ==
               Map.new(Map.from_struct(expected), fn {key, value} ->
                 {Atom.to_string(key), value}
               end)
    end
  end

  test "a keyword monitor without a keyword gets no assertion" do
    assert %{type: :http, settings: %{assertions: []}} = migrate!(keyword_monitor(%{}))
  end

  test "leaves other monitors alone" do
    monitor = monitor_fixture(:http)
    assert migrate!(monitor).settings == monitor.settings
  end
end
