defmodule Sentinelix.Repo.Migrations.AddGroupsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # The OIDC groups of the user (from the groups claim), refreshed on
      # every OIDC login. Local users have none.
      add :groups, {:array, :string}, null: false, default: []
    end
  end
end
