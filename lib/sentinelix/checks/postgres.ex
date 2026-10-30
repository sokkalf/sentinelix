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

  ## Result

  `:down` on connection, TLS, authentication and query errors, with the
  server's message (e.g. `password authentication failed for user "x"`).
  The response time covers connecting and querying; `meta` has them
  separately as `connect_ms` and `query_ms`, plus the number of `rows`.

  The password (`Monitor.secret(monitor, "password")`) is only passed to
  the connection; it is never part of a result message or `meta`.
  """

  @behaviour Sentinelix.Checks.Check

  alias Sentinelix.Checks.Postgres.Connection
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

  defp probe(conn, settings) do
    started = System.monotonic_time()

    case Connection.query(conn, settings.query) do
      {:ok, result, conn} ->
        query_ms = elapsed_ms(started)
        rows = result.num_rows || 0
        meta = %{query_ms: query_ms, rows: rows}
        {conn, {:up, %{message: "Query OK: #{pluralize_rows(rows)}", meta: meta}}}

      {:error, error, conn} ->
        meta = %{query_ms: elapsed_ms(started)}
        {conn, {:down, %{message: "Query failed: " <> format_error(error), meta: meta}}}
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
