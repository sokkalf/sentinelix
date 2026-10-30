defmodule Sentinelix.Mailer do
  @moduledoc """
  Swoosh mailer for notification emails.

  In production the adapter is `Swoosh.Adapters.SMTP`, configured from the
  `SMTP_*` environment variables (see config/runtime.exs). Without
  `SMTP_HOST` no adapter is configured: email notifications then fail with
  a clear error and a warning is logged on boot.
  """

  use Swoosh.Mailer, otp_app: :sentinelix

  require Logger

  @doc "Whether a mail adapter is configured."
  @spec configured?(keyword()) :: boolean()
  def configured?(config \\ Application.get_env(:sentinelix, __MODULE__, [])) do
    config[:adapter] != nil
  end

  @doc false
  def warn_if_unconfigured do
    unless configured?() do
      Logger.warning(
        "No mail adapter is configured (set SMTP_HOST): email notifications can't be sent"
      )
    end

    :ok
  end
end
