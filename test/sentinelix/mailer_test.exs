defmodule Sentinelix.MailerTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Mailer

  test "configured?/1 tells whether an adapter is set" do
    assert Mailer.configured?()
    assert Mailer.configured?(adapter: Swoosh.Adapters.SMTP, relay: "smtp.example.com")
    refute Mailer.configured?(adapter: nil)
    refute Mailer.configured?([])
  end
end
