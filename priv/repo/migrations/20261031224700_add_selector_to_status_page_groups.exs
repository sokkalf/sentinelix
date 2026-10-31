defmodule Sentinelix.Repo.Migrations.AddSelectorToStatusPageGroups do
  use Ecto.Migration

  # A group with a selector (see Sentinelix.Monitoring.Selector, stored in
  # its normalized form) shows the monitors it matches in addition to its
  # monitors in status_page_monitors, which are pinned first. NULL is a
  # fixed list; an empty selector is never stored.
  def change do
    alter table(:status_page_groups) do
      add :selector, :text
    end
  end
end
