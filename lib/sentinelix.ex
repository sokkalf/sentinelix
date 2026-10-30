defmodule Sentinelix do
  @moduledoc """
  Sentinelix keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  The name of the running build, as `Sentinelix.Version.name/0` gave it when
  it was built: `0.1.1` for a release, or the short SHA of a commit.

  The application carries it in SemVer, which puts a commit on `0.0.0` as
  build metadata; that is taken off again here.
  """
  @spec version() :: String.t()
  def version do
    case to_string(Application.spec(:sentinelix, :vsn)) do
      "0.0.0+" <> name -> name
      version -> version
    end
  end
end
