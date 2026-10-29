defmodule Sentinelix.Health do
  @moduledoc """
  The health check behind `GET /healthz`.
  """

  alias Sentinelix.Repo

  @doc """
  Checks that the database answers `SELECT 1`.

  Returns `{:ok, %{status: "ok", db: "ok"}}` or
  `{:error, %{status: "error", db: "error"}}`.
  """
  @spec check(module()) :: {:ok, map()} | {:error, map()}
  def check(repo \\ Repo) do
    case database(repo) do
      :ok -> {:ok, %{status: "ok", db: "ok"}}
      :error -> {:error, %{status: "error", db: "error"}}
    end
  end

  defp database(repo) do
    case repo.query("SELECT 1", [], timeout: 5_000, log: false) do
      {:ok, %{rows: [[1]]}} -> :ok
      _ -> :error
    end
  rescue
    # e.g. DBConnection.ConnectionError when no connection is available
    _exception -> :error
  catch
    :exit, _reason -> :error
  end
end
