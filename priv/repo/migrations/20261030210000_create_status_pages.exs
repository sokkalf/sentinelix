defmodule Sentinelix.Repo.Migrations.CreateStatusPages do
  use Ecto.Migration

  def change do
    create table(:status_pages) do
      add :slug, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :footer_text, :text
      add :published, :boolean, null: false, default: false
      # Show monitor targets (URLs, hosts) and check/incident messages on
      # the public page. Off by default: only names and statuses are shown.
      add :show_details, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:status_pages, [:slug])

    create table(:status_page_groups) do
      add :status_page_id, references(:status_pages, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:status_page_groups, [:status_page_id, :position])

    create table(:status_page_monitors) do
      add :group_id, references(:status_page_groups, on_delete: :delete_all), null: false
      add :monitor_id, references(:monitors, on_delete: :delete_all), null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:status_page_monitors, [:group_id, :monitor_id])
    create index(:status_page_monitors, [:monitor_id])
  end
end
