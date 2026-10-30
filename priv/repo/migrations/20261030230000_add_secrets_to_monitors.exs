defmodule Sentinelix.Repo.Migrations.AddSecretsToMonitors do
  use Ecto.Migration

  def change do
    alter table(:monitors) do
      # Type-specific secrets (e.g. a database password), encrypted with
      # Sentinelix.EncryptedMap. Kept out of the `settings` JSON.
      add :secrets, :binary
    end
  end
end
