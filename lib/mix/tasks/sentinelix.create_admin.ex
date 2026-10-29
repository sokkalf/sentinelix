defmodule Mix.Tasks.Sentinelix.CreateAdmin do
  @shortdoc "Creates a local (break-glass) admin user or resets its password"

  @moduledoc """
  Creates a local admin user for the password (break-glass) login, or resets
  the password of an existing local user with that email. Resetting the
  password revokes all of the user's sessions.

      $ mix sentinelix.create_admin --email admin@example.com
      $ mix sentinelix.create_admin --email admin@example.com --password "correct horse battery"

  Without `--password`, the password is read from `ADMIN_PASSWORD` or
  prompted for. Passwords must be 12-72 characters long.

  Local login is only offered when enabled, see `LOCAL_AUTH_ENABLED`
  (enabled by default when OIDC is not configured).
  """
  use Mix.Task

  @switches [email: :string, password: :string, name: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    email = opts[:email] || System.get_env("ADMIN_EMAIL") || prompt("Email: ")
    password = opts[:password] || System.get_env("ADMIN_PASSWORD") || prompt_password()

    Mix.Task.run("app.config")

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(Sentinelix.Repo, fn _repo ->
        Sentinelix.Accounts.create_or_reset_local_user(%{
          email: email,
          password: password,
          name: opts[:name]
        })
      end)

    case result do
      {:ok, :created, user} ->
        Mix.shell().info("Created local admin #{user.email}")

      {:ok, :updated, user} ->
        Mix.shell().info("Reset password of local admin #{user.email}")

      {:error, changeset} ->
        Mix.raise("Could not create admin: #{inspect(format_errors(changeset))}")
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, &interpolate(&1, &2, opts))
    end)
  end

  defp interpolate(_match, key, opts) do
    opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
  end

  defp prompt(label), do: label |> Mix.shell().prompt() |> String.trim()

  defp prompt_password do
    IO.write("Password: ")
    password = :io.get_password() |> to_string() |> String.trim()
    IO.write("\n")
    password
  end
end
