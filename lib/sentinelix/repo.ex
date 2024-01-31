defmodule Sentinelix.Repo do
  use Ecto.Repo,
    otp_app: :sentinelix,
    adapter: Ecto.Adapters.Postgres
end
