defmodule SentinelixWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use SentinelixWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Sentinelix.Accounts
  alias Sentinelix.Accounts.Scope
  alias Sentinelix.AccountsFixtures

  using do
    quote do
      # The default endpoint for testing
      @endpoint SentinelixWeb.Endpoint

      use SentinelixWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import SentinelixWeb.ConnCase
    end
  end

  setup tags do
    Sentinelix.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn() |> Map.put(:remote_ip, unique_ip())}
  end

  @doc """
  A client IP address unique to the calling test, so that per-IP rate limits
  (`Sentinelix.RateLimit`) don't leak between tests.
  """
  def unique_ip do
    <<a, b, c>> = <<System.unique_integer([:positive])::24>>
    {10, a, b, c}
  end

  @doc """
  Setup helper that creates a local user and logs it in.

      setup :register_and_log_in_user

  It stores an updated connection, the user and its scope in the test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = AccountsFixtures.user_fixture(Map.get(context, :user_attrs, %{}))
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn` by creating a session token.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = Accounts.generate_user_session_token(user, opts)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  end
end
