defmodule Sentinelix.Repo.Migrations.CreateSavedViews do
  use Ecto.Migration

  def change do
    create table(:saved_views) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      # Stable: kept when the view is renamed (wall/kiosk links use it).
      add :slug, :string, null: false
      # The view as URL parameters (Sentinelix.Monitoring.View.to_params/1),
      # so new view settings need no migration.
      add :params, :map, null: false, default: %{}
      add :visibility, :string, null: false, default: "personal"
      # OIDC groups, for visibility "groups".
      add :groups, {:array, :string}, null: false, default: []
      # The order of the owner's views.
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:saved_views, [:slug])
    create index(:saved_views, [:owner_id])
    create index(:saved_views, [:groups], using: :gin)

    alter table(:users) do
      # The view shown at `/`; cleared when the view is deleted.
      add :default_view_id, references(:saved_views, on_delete: :nilify_all)
    end
  end
end
