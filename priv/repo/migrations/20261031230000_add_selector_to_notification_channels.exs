defmodule Sentinelix.Repo.Migrations.AddSelectorToNotificationChannels do
  use Ecto.Migration

  # A channel's selector (see Sentinelix.Monitoring.Selector) routes the
  # monitors it matches to the channel, in addition to the attached ones.
  # Stored as its normalized text; "" means no routing (not "every
  # monitor", which an empty selector means elsewhere).
  def change do
    alter table(:notification_channels) do
      add :selector, :text, null: false, default: ""
    end
  end
end
