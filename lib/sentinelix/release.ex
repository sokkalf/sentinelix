defmodule Sentinelix.Release do
  @moduledoc """
  Tasks for production releases, where Mix isn't available.

      bin/migrate                     # runs Sentinelix.Release.migrate/0
      bin/sentinelix eval "Sentinelix.Release.rollback(Sentinelix.Repo, 20250101000000)"
      ADMIN_EMAIL=admin@example.com ADMIN_PASSWORD=... bin/create_admin

  In the Docker image, `bin/migrate` runs before the server starts (see
  `rel/overlays/bin/start`).
  """
  @app :sentinelix

  @doc "Runs all pending migrations."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Rolls `repo` back to (and including) migration `version`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Creates a local (break-glass) admin, or resets the password of an existing
  local user with that email (revoking its sessions) – the release
  counterpart of `mix sentinelix.create_admin`.

  Options: `:email`, `:password`, `:name`. Email and password default to
  the `ADMIN_EMAIL` and `ADMIN_PASSWORD` environment variables. Raises if
  they are missing or invalid (passwords must be 12-72 characters long), so
  `bin/create_admin` exits with a non-zero status.

  Returns `{:ok, :created | :updated, user}`.
  """
  def create_admin(opts \\ []) do
    email = opts[:email] || System.get_env("ADMIN_EMAIL")
    password = opts[:password] || System.get_env("ADMIN_PASSWORD")

    if blank?(email) or blank?(password) do
      raise ArgumentError,
            "an email and a password are required (set ADMIN_EMAIL and ADMIN_PASSWORD)"
    end

    load_app()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(Sentinelix.Repo, fn _repo ->
        Sentinelix.Accounts.create_or_reset_local_user(%{
          email: email,
          password: password,
          name: opts[:name]
        })
      end)

    case result do
      {:ok, :created, user} = ok ->
        IO.puts("Created local admin #{user.email}")
        ok

      {:ok, :updated, user} = ok ->
        IO.puts("Reset password of local admin #{user.email}")
        ok

      {:error, changeset} ->
        raise ArgumentError, "could not create admin: #{inspect(format_errors(changeset))}"
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _match, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
