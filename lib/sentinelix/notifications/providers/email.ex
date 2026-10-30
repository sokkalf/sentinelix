defmodule Sentinelix.Notifications.Providers.Email do
  @moduledoc """
  Email via `Sentinelix.Mailer` (Swoosh).

  The sender defaults to `"Sentinelix" <sentinelix@localhost>` and can be
  changed with

      config :sentinelix, Sentinelix.Notifications, email_from: {"Sentinelix", "alerts@example.com"}

  (`NOTIFICATIONS_EMAIL_FROM` in production, see config/runtime.exs). The
  mailer adapter itself is configured on `Sentinelix.Mailer` (SMTP in
  production); sends fail with an error while none is configured.
  """

  use Sentinelix.Notifications.Provider

  import Swoosh.Email

  alias Sentinelix.Notifications.{Event, Provider}

  @impl true
  def label, do: "Email"

  @impl true
  def fields do
    [
      %{
        key: "to",
        label: "Recipients",
        type: :email,
        required: true,
        placeholder: "ops@example.com, oncall@example.com",
        help: "Comma separated email addresses"
      }
    ]
  end

  @impl true
  def send(channel, event) do
    if Sentinelix.Mailer.configured?(),
      do: deliver(channel, event),
      else: {:error, "no mail adapter is configured (set SMTP_HOST)"}
  end

  defp deliver(channel, event) do
    email =
      new()
      |> to(Provider.split_list(channel.config["to"]))
      |> from(from())
      |> subject(Event.title(event))
      |> text_body(Event.text(event) <> "\n\n-- \nSentinelix\n")

    case Sentinelix.Mailer.deliver(email) do
      {:ok, _meta} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp from do
    Application.get_env(:sentinelix, Sentinelix.Notifications, [])
    |> Keyword.get(:email_from, {"Sentinelix", "sentinelix@localhost"})
  end
end
