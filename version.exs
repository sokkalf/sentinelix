defmodule Sentinelix.Version do
  @moduledoc """
  What this build of Sentinelix calls itself, read from git.

  A checkout sitting exactly on a tag with nothing changed is that tag, less
  its `v`: `v0.2.0` is `0.2.0`. Anything else is a commit and not a release,
  and is called by its short SHA — a commit past the tag, a tag with edits on
  top of it, a repository with no tags at all. A tag that is not a version
  (`release-2`) is no version either, and is the SHA too.

  The image is built without `.git`, so the build passes the name in instead:
  `SENTINELIX_VERSION`, which wins over git wherever it is set (see the
  `Dockerfile`). With neither, the build is `unknown`.

  `mix.exs` requires this file, so the application and the release carry
  this version.
  """

  @doc "The name of the build: `0.2.0`, or `2179ad1`."
  @spec name() :: String.t()
  def name do
    case System.get_env("SENTINELIX_VERSION", "") do
      "" -> from_git() || "unknown"
      given -> String.trim_leading(given, "v")
    end
  end

  @doc """
  The same name as Mix and the release want it, which is SemVer: a release
  is its own version, and a commit goes in as build metadata on `0.0.0`.
  """
  @spec semver() :: String.t()
  def semver do
    name = name()

    case Version.parse(name) do
      {:ok, _version} -> name
      :error -> "0.0.0+" <> String.replace(name, ~r/[^0-9A-Za-z-]/, "-")
    end
  end

  defp from_git do
    with {:ok, sha} <- git(~w(rev-parse --short HEAD)) do
      # `--dirty` marks a tag with changes on top of it, which is not that tag.
      case git(~w(describe --tags --exact-match --dirty)) do
        {:ok, tag} -> release(tag) || sha
        :error -> sha
      end
    else
      :error -> nil
    end
  end

  defp release(tag) do
    version = String.trim_leading(tag, "v")

    if not String.ends_with?(tag, "-dirty") and match?({:ok, _}, Version.parse(version)),
      do: version
  end

  defp git(args) do
    with git when is_binary(git) <- System.find_executable("git"),
         {out, 0} <- System.cmd(git, args, cd: __DIR__, stderr_to_stdout: true) do
      {:ok, String.trim(out)}
    else
      _ -> :error
    end
  end
end
