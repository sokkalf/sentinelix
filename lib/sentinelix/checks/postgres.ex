defmodule Sentinelix.Checks.Postgres do
  @moduledoc """
  PostgreSQL check.

  Opens a fresh connection to the server (a successful login is part of
  what is checked), runs the monitor's `query` and closes the connection
  again. Each check uses exactly one short-lived connection, see
  `Sentinelix.Checks.Postgres.Connection`.

  ## Read-only

  The connection is opened with `default_transaction_read_only = on`, so
  the query runs in a read-only transaction: a mistyped `DELETE` fails
  instead of deleting anything. Only a single statement can be run (the
  extended query protocol rejects multiple statements). The query is also
  bounded by `statement_timeout` set to the monitor's `timeout_ms`. A
  dedicated low-privilege role should be used anyway.

  ## SSL modes

    * `"disable"` – no TLS.
    * `"require"` – TLS, but the server certificate is not verified.
    * `"verify-full"` – TLS with the certificate chain verified against
      `ssl_ca_cert` (or the system CAs) and the hostname checked.

  ## Expected result

  Optionally, the first value of the result (`expected_value` with
  `comparison`) and the number of rows (`expected_rows` with
  `rows_comparison`) are checked, see
  `Sentinelix.Checks.Postgres.Expectation`. A failed assertion is `:down`
  with the actual value in the message, e.g. `got "42", expected > 100`.

  ## Replication

  With `replication_check` set to `"primary"` or `"standby"`, the
  replication status is checked after the query (on the same connection),
  see `Sentinelix.Checks.Postgres.Replication`. Lag above a warning
  threshold is `:up` with `warning: true`; the lag is in
  `meta.replication`.

  ## Result

  `:down` on connection, TLS, authentication and query errors, with the
  server's message (e.g. `password authentication failed for user "x"`).
  The response time covers connecting and querying; `meta` has them
  separately as `connect_ms` and `query_ms`, plus the number of `rows`.

  The password (`Monitor.secret(monitor, "password")`) is only passed to
  the connection; it is never part of a result message or `meta`.
  """

  @behaviour Sentinelix.Checks.Check

  alias Sentinelix.Checks.Postgres.{Connection, Expectation, Replication}
  alias Sentinelix.Monitoring.{Monitor, Settings}

  @application_name "sentinelix"

  @impl true
  def run(%Monitor{settings: %Settings{} = settings} = monitor) do
    started = System.monotonic_time()

    case Connection.connect(connect_options(monitor)) do
      {:ok, conn} ->
        connect_ms = elapsed_ms(started)
        {conn, {status, details}} = probe(conn, settings)
        Connection.close(conn)

        meta = Map.put(details[:meta] || %{}, :connect_ms, connect_ms)

        {status,
         details |> Map.put(:meta, meta) |> Map.put(:response_time_ms, elapsed_ms(started))}

      {:error, error} ->
        connect_ms = elapsed_ms(started)

        {:down,
         %{
           message: "Connection failed: " <> format_error(error),
           response_time_ms: connect_ms,
           meta: %{connect_ms: connect_ms}
         }}
    end
  rescue
    # The worker would record the exception banner, which might contain
    # the connection options.
    error -> {:down, %{message: "Check failed: unexpected error (#{inspect(error.__struct__)})"}}
  end

  # The query, then (if it succeeded) the replication status, on the same
  # connection.
  defp probe(conn, settings) do
    case run_query(conn, settings) do
      {conn, {:up, details}} -> check_replication(conn, settings, details)
      {conn, down} -> {conn, down}
    end
  end

  defp run_query(conn, settings) do
    started = System.monotonic_time()

    case Connection.query(conn, settings.query) do
      {:ok, result, conn} ->
        meta = %{query_ms: elapsed_ms(started), rows: result.num_rows || 0}
        {status, message} = evaluate(result, settings)
        {conn, {status, %{message: message, meta: meta}}}

      {:error, error, conn} ->
        meta = %{query_ms: elapsed_ms(started)}
        {conn, {:down, %{message: "Query failed: " <> format_error(error), meta: meta}}}
    end
  end

  defp check_replication(conn, %Settings{replication_check: mode} = settings, query_details)
       when mode in ["primary", "standby"] do
    case Replication.fetch(conn, mode) do
      {:ok, data, conn} ->
        {status, details} = Replication.evaluate(data, settings)

        {conn,
         {status,
          %{
            message: query_details.message <> "; " <> details.message,
            warning: details.warning,
            meta: Map.put(query_details.meta, :replication, details.meta)
          }}}

      {:error, error, conn} ->
        message = "Replication status query failed: " <> format_error(error)
        {conn, {:down, %{query_details | message: query_details.message <> "; " <> message}}}
    end
  end

  defp check_replication(conn, _settings, query_details), do: {conn, {:up, query_details}}

  defp evaluate(result, settings) do
    rows =
      Expectation.check_rows(
        result,
        settings.expected_rows,
        settings.rows_comparison || "equals"
      )

    value =
      Expectation.check_value(result, settings.expected_value, settings.comparison || "equals")

    ok = "Query OK: " <> pluralize_rows(result.num_rows || 0)

    case {rows, value} do
      {{:error, message}, _value} -> {:down, "Unexpected result: " <> message}
      {_rows, {:error, message}} -> {:down, "Unexpected result: " <> message}
      {_rows, {:ok, message}} -> {:up, ok <> ", " <> message}
      {_rows, :skip} -> {:up, ok}
    end
  end

  @doc """
  The Postgrex connection options for a monitor.
  """
  @spec connect_options(Monitor.t()) :: keyword()
  def connect_options(%Monitor{settings: settings, timeout_ms: timeout} = monitor) do
    password =
      case Monitor.secret(monitor, "password") do
        nil -> []
        password -> [password: password]
      end

    [
      hostname: settings.host,
      port: settings.port,
      database: settings.database,
      username: settings.username,
      ssl: ssl_options(settings),
      # Without it, Nagle's algorithm and the server's delayed ACK add
      # ~40 ms to every TLS login (the handshake's last message and the
      # startup message are sent back to back).
      socket_options: [nodelay: true],
      timeout: timeout,
      connect_timeout: timeout,
      parameters: [
        application_name: @application_name,
        default_transaction_read_only: "on",
        statement_timeout: Integer.to_string(timeout)
      ]
    ] ++ password
  end

  defp ssl_options(%Settings{ssl_mode: "disable"}), do: false

  defp ssl_options(%Settings{ssl_mode: "verify-full"} = settings) do
    cacerts =
      with pem when is_binary(pem) <- settings.ssl_ca_cert,
           {:ok, certs} <- Settings.parse_ca_certs(pem) do
        certs
      else
        _ -> :public_key.cacerts_get()
      end

    # Postgrex adds SNI and hostname verification.
    [verify: :verify_peer, cacerts: cacerts, log_level: :error]
  end

  defp ssl_options(%Settings{}), do: [verify: :verify_none, log_level: :error]

  @doc """
  A human readable message for a connection or query error.
  """
  @spec format_error(Exception.t()) :: String.t()
  def format_error(%Postgrex.Error{postgres: %{message: message}}), do: message
  def format_error(%Postgrex.Error{message: message}) when is_binary(message), do: message

  def format_error(%DBConnection.ConnectionError{message: message}) do
    case Regex.run(~r/ALERT: Fatal - ([^\n]+)(?:\n\s*(\w+))?/, message) do
      [_, alert, detail] -> "TLS handshake failed: #{alert} (#{detail})"
      [_, alert] -> "TLS handshake failed: #{alert}"
      # "tcp connect (host:5432): connection refused - :econnrefused"
      nil -> String.replace(message, ~r/ - [:{].*\z/s, "")
    end
  end

  def format_error(error), do: Exception.message(error)

  defp pluralize_rows(1), do: "1 row"
  defp pluralize_rows(n), do: "#{n} rows"

  defp elapsed_ms(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
end
