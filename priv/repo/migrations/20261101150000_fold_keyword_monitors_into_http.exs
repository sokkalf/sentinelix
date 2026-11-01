defmodule Sentinelix.Repo.Migrations.FoldKeywordMonitorsIntoHttp do
  use Ecto.Migration

  # The keyword monitor type is replaced by response assertions on HTTP
  # monitors (see Sentinelix.Monitoring.Settings.Assertion). Every keyword
  # monitor becomes an http monitor with a single assertion, mirroring
  # Settings.Assertion.from_keyword/1:
  #
  #   * without json_path: body contains keyword (not_contains if inverted)
  #   * with json_path: json <json_path> equals keyword (not_equals if
  #     inverted)
  #
  # case_sensitive carries over; the keyword fields are removed from the
  # settings and the automatic `type` label follows the type.
  def up, do: execute(sql())

  @doc false
  # Public for the test of the conversion.
  def sql do
    """
    UPDATE monitors
       SET type = 'http',
           auto_labels = auto_labels || '{"type": "http"}'::jsonb,
           settings = (settings - 'keyword' - 'invert_keyword' - 'case_sensitive' - 'json_path')
             || jsonb_build_object('assertions',
                  CASE WHEN COALESCE(settings->>'keyword', '') = '' THEN '[]'::jsonb
                  ELSE jsonb_build_array(jsonb_build_object(
                    'source', CASE WHEN COALESCE(btrim(settings->>'json_path'), '') = ''
                                   THEN 'body' ELSE 'json' END,
                    'path', NULLIF(btrim(settings->>'json_path'), ''),
                    'comparison',
                      CASE WHEN COALESCE(btrim(settings->>'json_path'), '') = '' THEN
                        CASE WHEN settings->>'invert_keyword' = 'true'
                             THEN 'not_contains' ELSE 'contains' END
                      ELSE
                        CASE WHEN settings->>'invert_keyword' = 'true'
                             THEN 'not_equals' ELSE 'equals' END
                      END,
                    'value', settings->>'keyword',
                    'case_sensitive', settings->>'case_sensitive' IS DISTINCT FROM 'false'))
                  END)
     WHERE type = 'keyword'
    """
  end

  # The converted monitors can't be told apart from other http monitors
  # with assertions, so they stay http monitors.
  def down, do: :ok
end
