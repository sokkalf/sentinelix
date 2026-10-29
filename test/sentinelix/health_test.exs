defmodule Sentinelix.HealthTest do
  use Sentinelix.DataCase, async: true

  alias Sentinelix.Health

  defmodule ErrorRepo do
    def query(_sql, _params, _opts), do: {:error, %DBConnection.ConnectionError{message: "down"}}
  end

  defmodule RaisingRepo do
    def query(_sql, _params, _opts), do: raise(DBConnection.ConnectionError, "down")
  end

  defmodule ExitingRepo do
    def query(_sql, _params, _opts), do: exit(:timeout)
  end

  test "ok when the database answers" do
    assert Health.check() == {:ok, %{status: "ok", db: "ok"}}
  end

  test "error when the query fails, raises or exits" do
    for repo <- [ErrorRepo, RaisingRepo, ExitingRepo] do
      assert Health.check(repo) == {:error, %{status: "error", db: "error"}}
    end
  end
end
