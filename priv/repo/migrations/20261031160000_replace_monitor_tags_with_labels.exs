defmodule Sentinelix.Repo.Migrations.ReplaceMonitorTagsWithLabels do
  use Ecto.Migration

  # Key/value labels (see Sentinelix.Monitoring.Labels) replace the free-form
  # tags. Every tag becomes a label without a value (`{"prod": ""}`), except
  # "key=value" tags (as written by `down/0`), which keep their value. Keys
  # are normalized to the label key rules: lowercased, runs of other
  # characters replaced by "-", starting with a letter or digit, at most 63
  # characters; values likewise, keeping their case.
  def up do
    alter table(:monitors) do
      add :labels, :map, null: false, default: fragment("'{}'::jsonb")
    end

    execute("""
    UPDATE monitors AS m SET labels = COALESCE(
      (SELECT jsonb_object_agg(key, value)
         FROM (SELECT left(
                        regexp_replace(
                          regexp_replace(lower(btrim(split_part(tag, '=', 1))),
                                         '[^a-z0-9_./-]+', '-', 'g'),
                          '^[^a-z0-9]+', ''),
                        63) AS key,
                      left(
                        regexp_replace(btrim(substr(tag, length(split_part(tag, '=', 1)) + 2)),
                                       '[^A-Za-z0-9_.:/@-]+', '-', 'g'),
                        255) AS value
                 FROM unnest(m.tags) AS tag) AS labels
        WHERE key <> ''),
      '{}'::jsonb)
    """)

    # Serves the containment (`@>`) and key existence (`?`) queries of
    # label selectors.
    create index(:monitors, [:labels], using: :gin)

    alter table(:monitors) do
      remove :tags
    end
  end

  # Labels become tags again, written as "key=value" (or "key").
  def down do
    alter table(:monitors) do
      add :tags, {:array, :string}, null: false, default: []
    end

    execute("""
    UPDATE monitors SET tags = ARRAY(
      SELECT CASE WHEN value = '' THEN key ELSE key || '=' || value END
        FROM jsonb_each_text(labels)
       ORDER BY key)
    """)

    drop index(:monitors, [:labels])

    alter table(:monitors) do
      remove :labels
    end
  end
end
