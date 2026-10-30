defmodule Sentinelix.Checks.PostgresTest do
  # Runs against the test database server (see config/test.exs). The check
  # opens its own connections, outside of the SQL sandbox.
  use Sentinelix.DataCase, async: true

  alias Sentinelix.Checks.Postgres
  alias Sentinelix.Monitoring.{Monitor, Settings}
  alias Sentinelix.Repo

  defp server do
    config = Repo.config()

    %{
      host: config[:hostname] || "localhost",
      port: config[:port] || 5432,
      database: config[:database],
      username: config[:username],
      password: config[:password]
    }
  end

  defp monitor(settings \\ %{}, opts \\ []) do
    server = server()

    settings =
      Settings.defaults_for(:postgres)
      |> Map.merge(%{
        host: server.host,
        port: server.port,
        database: server.database,
        username: server.username,
        ssl_mode: "disable",
        query: "SELECT 1"
      })
      |> Map.merge(settings)

    %Monitor{
      type: :postgres,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
      settings: struct!(Settings, settings),
      secrets: %{"password" => Keyword.get(opts, :password, server.password)}
    }
  end

  # A separate connection to observe the server (pg_stat_activity is a
  # snapshot within the sandbox transaction).
  defp observer do
    server = server()

    start_supervised!(
      {Postgrex,
       hostname: server.host,
       port: server.port,
       database: server.database,
       username: server.username,
       password: server.password}
    )
  end

  defp backends(conn, marker) do
    %{rows: [[count]]} =
      Postgrex.query!(
        conn,
        "SELECT count(*) FROM pg_stat_activity WHERE query LIKE $1 AND pid <> pg_backend_pid()",
        ["%#{marker}%"]
      )

    count
  end

  defp eventually(fun, timeout \\ 3_000) do
    cond do
      fun.() ->
        true

      timeout <= 0 ->
        false

      true ->
        Process.sleep(25)
        eventually(fun, timeout - 25)
    end
  end

  describe "connecting and querying" do
    test "is up when the query succeeds" do
      assert {:up, details} = Postgres.run(monitor())
      assert details.message == "Query OK: 1 row"
      assert %{connect_ms: connect_ms, query_ms: query_ms, rows: 1} = details.meta
      assert details.response_time_ms >= connect_ms + query_ms
    end

    test "is down with the server's message on a wrong password" do
      assert {:down, %{message: message}} = Postgres.run(monitor(%{}, password: "wrong"))

      assert message ==
               ~s(Connection failed: password authentication failed for user "#{server().username}")
    end

    test "uses no password from the environment when none is configured" do
      # config/test.exs and CI set PGPASSWORD, which Postgrex.start_link/1
      # would fall back to.
      monitor = %{monitor() | secrets: %{}}
      refute Keyword.has_key?(Postgres.connect_options(monitor), :password)

      assert {:down, %{message: "Connection failed: the server requires a password"}} =
               Postgres.run(monitor)
    end

    test "is down for an unknown database" do
      assert {:down, %{message: message}} =
               Postgres.run(monitor(%{database: "sentinelix_does_not_exist"}))

      assert message ==
               ~s(Connection failed: database "sentinelix_does_not_exist" does not exist)
    end

    test "is down when the connection is refused" do
      assert {:down, %{message: message, meta: %{connect_ms: _}}} =
               Postgres.run(monitor(%{host: "127.0.0.1", port: 1}))

      assert message == "Connection failed: tcp connect (127.0.0.1:1): connection refused"
    end

    test "is down when the query fails" do
      assert {:down, %{message: message, meta: %{connect_ms: _, query_ms: _}}} =
               Postgres.run(monitor(%{query: "SELECT * FROM sentinelix_no_such_table"}))

      assert message == ~s(Query failed: relation "sentinelix_no_such_table" does not exist)

      assert {:down, %{message: "Query failed: syntax error at or near \"SELEC\""}} =
               Postgres.run(monitor(%{query: "SELEC 1"}))
    end

    test "runs the query read-only and as a single statement" do
      assert {:down, %{message: message}} =
               Postgres.run(monitor(%{query: "CREATE TABLE sentinelix_must_not_exist (id int)"}))

      assert message == "Query failed: cannot execute CREATE TABLE in a read-only transaction"

      assert {:down, %{message: message}} =
               Postgres.run(
                 monitor(%{query: "WITH d AS (DELETE FROM monitors RETURNING 1) SELECT 1"})
               )

      # (PostgreSQL names the outer SELECT here.)
      assert message =~ ~r/^Query failed: cannot execute \w+ in a read-only transaction$/

      assert {:down, %{message: message}} =
               Postgres.run(
                 monitor(%{
                   query: "SET default_transaction_read_only = off; DELETE FROM monitors"
                 })
               )

      assert message == "Query failed: cannot insert multiple commands into a prepared statement"
    end

    test "bounds the query with the monitor's timeout" do
      assert {:down, %{message: message}} =
               Postgres.run(monitor(%{query: "SELECT pg_sleep(5)"}, timeout_ms: 300))

      assert message == "Query failed: canceling statement due to statement timeout"
    end

    test "connects with SSL when required" do
      %{rows: [[ssl]]} = Repo.query!("SHOW ssl")

      case {ssl, Postgres.run(monitor(%{ssl_mode: "require"}))} do
        {"on", result} ->
          assert {:up, _} = result

        {"off", result} ->
          assert {:down, %{message: "Connection failed: ssl not available"}} = result
      end
    end

    test "leaves the calling process killable" do
      assert {:up, _} = Postgres.run(monitor())
      assert Process.info(self(), :trap_exit) == {:trap_exit, false}
    end
  end

  describe "expected result" do
    test "checks the first value" do
      assert {:up, %{message: ~s(Query OK: 1 row, got "42")}} =
               Postgres.run(monitor(%{query: "SELECT 42", expected_value: "42"}))

      assert {:down, %{message: ~s(Unexpected result: got "42", expected > 100)}} =
               Postgres.run(
                 monitor(%{query: "SELECT 42", expected_value: "100", comparison: ">"})
               )

      assert {:up, _} =
               Postgres.run(
                 monitor(%{
                   query: "SELECT version()",
                   expected_value: "PostgreSQL",
                   comparison: "contains"
                 })
               )

      # Freshness: a boolean.
      assert {:up, _} =
               Postgres.run(
                 monitor(%{
                   query: "SELECT now() > now() - interval '10 min'",
                   expected_value: "true"
                 })
               )
    end

    test "converts typed values to text" do
      for {sql, text} <- [
            {"SELECT 1.50::numeric", "1.50"},
            {"SELECT 2::float8 / 4", "0.5"},
            {"SELECT NULL", "NULL"},
            {"SELECT DATE '2026-10-30'", "2026-10-30"},
            {"SELECT TIMESTAMPTZ '2026-10-30 12:00:00+00'", "2026-10-30T12:00:00Z"},
            {"SELECT interval '1 day 2 hours'", "1 day 02:00:00"},
            {"SELECT ARRAY[1, 2]", "{1,2}"},
            {"SELECT 'a'::text", "a"},
            {"SELECT '\\x00ff'::bytea", "\\x00ff"}
          ] do
        assert {:up, _} = Postgres.run(monitor(%{query: sql, expected_value: text})),
               "#{sql} should be #{text}"
      end

      assert {:up, _} =
               Postgres.run(
                 monitor(%{
                   query: "SELECT count(*) FROM pg_class",
                   expected_value: "0",
                   comparison: ">"
                 })
               )
    end

    test "checks the number of rows" do
      assert {:up, %{message: "Query OK: 0 rows"}} =
               Postgres.run(
                 monitor(%{
                   query: "SELECT 1 WHERE false",
                   expected_rows: 0,
                   rows_comparison: "<="
                 })
               )

      assert {:down, %{message: "Unexpected result: got 3 rows, expected <= 0"}} =
               Postgres.run(
                 monitor(%{
                   query: "SELECT generate_series(1, 3)",
                   expected_rows: 0,
                   rows_comparison: "<="
                 })
               )

      assert {:down, %{message: ~s(Unexpected result: got no rows, expected "1")}} =
               Postgres.run(monitor(%{query: "SELECT 1 WHERE false", expected_value: "1"}))
    end
  end

  # The test server is a primary. Whether its replication status can be
  # read depends on the test role (superuser in CI).
  defp replication_access do
    %{rows: [[privileged, streaming]]} =
      Repo.query!("""
      SELECT pg_has_role('pg_read_all_stats', 'USAGE'),
             (SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming')
      """)

    {privileged, streaming}
  end

  describe "replication" do
    test "checks a primary's standbys after the query" do
      result = Postgres.run(monitor(%{replication_check: "primary"}))

      case replication_access() do
        {false, _streaming} ->
          assert {:down, %{message: message}} = result

          assert message ==
                   "Query OK: 1 row; Insufficient privileges to read the replication status (grant pg_monitor)"

        {true, 0} ->
          assert {:down, %{message: "Query OK: 1 row; 0 of 1 standbys streaming", meta: meta}} =
                   result

          assert %{replication: %{role: :primary, standbys_streaming: 0}} = meta

        {true, _streaming} ->
          assert {status, _details} = result
          assert status in [:up, :down]
      end
    end

    test "a primary expected to be a standby is a role mismatch" do
      assert {:down, %{message: message, meta: %{replication: %{role: :primary}}}} =
               Postgres.run(monitor(%{replication_check: "standby"}))

      assert message ==
               "Query OK: 1 row; Expected a standby, but the server is not in recovery (failover?)"
    end

    test "is not checked when the query fails" do
      assert {:down, %{message: "Query failed: " <> _}} =
               Postgres.run(monitor(%{query: "SELEC 1", replication_check: "standby"}))
    end
  end

  test "killing a running check closes its connection" do
    observer = observer()
    marker = "sentinelix_kill_#{System.unique_integer([:positive])}"
    monitor = monitor(%{query: "SELECT pg_sleep(1) /* #{marker} */"})

    task = Task.async(fn -> Postgres.run(monitor) end)
    Process.unlink(task.pid)
    assert eventually(fn -> backends(observer, marker) == 1 end)

    sockets =
      for port <- Port.list(), Port.info(port, :connected) == {:connected, task.pid}, do: port

    assert [_socket] = sockets

    # The worker kills timed out checks.
    Process.exit(task.pid, :kill)

    assert eventually(fn -> Enum.all?(sockets, &(Port.info(&1) == nil)) end)
    # The server notices once pg_sleep returns.
    assert eventually(fn -> backends(observer, marker) == 0 end)
  end

  describe "format_error/1" do
    test "shortens connection and TLS errors" do
      error = %DBConnection.ConnectionError{
        message:
          "ssl connect: TLS client: In state wait_cert_cr at ssl_handshake.erl:2180 generated " <>
            "CLIENT ALERT: Fatal - Bad Certificate\n selfsigned_peer - {:tls_alert, {:bad_certificate, ~c\"...\"}}"
      }

      assert Postgres.format_error(error) ==
               "TLS handshake failed: Bad Certificate (selfsigned_peer)"

      error = %DBConnection.ConnectionError{
        message: "tcp connect (nonexistent.invalid:5432): non-existing domain - :nxdomain"
      }

      assert Postgres.format_error(error) ==
               "tcp connect (nonexistent.invalid:5432): non-existing domain"
    end
  end
end
