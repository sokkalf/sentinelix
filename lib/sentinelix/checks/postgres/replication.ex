defmodule Sentinelix.Checks.Postgres.Replication do
  @moduledoc """
  Replication status of a PostgreSQL server, read from built-in views and
  functions (PostgreSQL ≥ 10, no extensions).

  `fetch/2` queries the server, `evaluate/2` turns the data into a check
  result. The monitor's `replication_check` setting is also a **role
  assertion**: a server expected to be a standby that is not in recovery
  (or the other way around) is `:down` – a failover happened.

  Reading the replication views needs the `pg_monitor` role (or
  superuser); without it the interesting columns are `NULL`. That is
  detected (`pg_read_all_stats`, which `pg_monitor` includes) and reported
  as down instead of a bogus lag of 0.

  ## Standby

    * The WAL receiver must be `streaming` (`pg_stat_wal_receiver`).
    * Byte lag: received but not yet replayed WAL.
    * Time lag: time since the last replayed transaction – but 0 when
      everything received has been replayed, so an idle primary doesn't
      look like lag.

  ## Primary

    * At least `min_standbys` WAL senders (`pg_stat_replication`) must be
      `streaming`; fewer is down.
    * Lag: the largest `replay_lag` and byte lag (current WAL position
      minus the standby's replay position) over the streaming standbys.
      Per-standby details are in `meta.standbys`.
    * Inactive replication slots are a warning: they make the primary
      retain WAL, a classic way to fill up the disk.

  ## Thresholds

  `lag_warn_seconds` / `lag_critical_seconds` and `lag_warn_bytes` /
  `lag_critical_bytes` (each optional): reaching a warning threshold is
  `:up` with a warning, reaching a critical one is `:down`.
  """

  alias Sentinelix.Checks.Postgres.Connection
  alias Sentinelix.Monitoring.Settings

  @modes ~w(none primary standby)

  @doc "Allowed `replication_check` settings."
  def modes, do: @modes

  @type data :: %{
          required(:mode) => String.t(),
          required(:in_recovery) => boolean(),
          required(:privileged) => boolean(),
          optional(:receiver) => map(),
          optional(:standbys) => [map()],
          optional(:inactive_slots) => [map()]
        }

  @role_sql "SELECT pg_is_in_recovery(), pg_has_role('pg_read_all_stats', 'USAGE')"

  @standby_sql """
  SELECT (SELECT status FROM pg_stat_wal_receiver LIMIT 1),
         pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())::bigint,
         CASE WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
              ELSE extract(epoch FROM now() - pg_last_xact_replay_timestamp())
         END::float8
  """

  @standbys_sql """
  SELECT application_name, client_addr::text, state, sync_state,
         extract(epoch FROM write_lag)::float8,
         extract(epoch FROM flush_lag)::float8,
         extract(epoch FROM replay_lag)::float8,
         pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint
  FROM pg_stat_replication
  ORDER BY application_name, client_addr
  """

  @slots_sql """
  SELECT slot_name, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint
  FROM pg_replication_slots
  WHERE NOT active
  ORDER BY slot_name
  """

  @doc """
  Reads the replication status for `mode` (`"primary"` or `"standby"`).

  Only the server's role and privileges are read when they don't match
  `mode` – `evaluate/2` reports that.
  """
  @spec fetch(Connection.t(), String.t()) ::
          {:ok, data(), Connection.t()} | {:error, Exception.t(), Connection.t()}
  def fetch(conn, mode) when mode in ["primary", "standby"] do
    with {:ok, %{rows: [[in_recovery, privileged]]}, conn} <- Connection.query(conn, @role_sql) do
      data = %{mode: mode, in_recovery: in_recovery, privileged: privileged}

      case {mode, in_recovery, privileged} do
        {"standby", true, true} -> fetch_standby(conn, data)
        {"primary", false, true} -> fetch_primary(conn, data)
        _mismatch_or_unprivileged -> {:ok, data, conn}
      end
    end
  end

  defp fetch_standby(conn, data) do
    with {:ok, %{rows: [[status, lag_bytes, lag_seconds]]}, conn} <-
           Connection.query(conn, @standby_sql) do
      receiver = %{status: status, lag_bytes: lag_bytes, lag_seconds: lag_seconds}
      {:ok, Map.put(data, :receiver, receiver), conn}
    end
  end

  defp fetch_primary(conn, data) do
    with {:ok, %{rows: standby_rows}, conn} <- Connection.query(conn, @standbys_sql),
         {:ok, %{rows: slot_rows}, conn} <- Connection.query(conn, @slots_sql) do
      standbys =
        for [name, client_addr, state, sync_state, write, flush, replay, lag_bytes] <-
              standby_rows do
          %{
            name: name,
            client_addr: client_addr,
            state: state,
            sync_state: sync_state,
            write_lag: write,
            flush_lag: flush,
            replay_lag: replay,
            lag_bytes: lag_bytes
          }
        end

      slots = for [name, retained] <- slot_rows, do: %{name: name, retained_bytes: retained}

      {:ok, Map.merge(data, %{standbys: standbys, inactive_slots: slots}), conn}
    end
  end

  @doc """
  Evaluates replication data (see `fetch/2`) against the monitor settings.

  Returns `{status, details}` with `:message`, `:meta` and `:warning`.
  """
  @spec evaluate(data(), Settings.t()) :: Sentinelix.Checks.Check.result()
  def evaluate(%{mode: "standby", in_recovery: false}, _settings) do
    down("Expected a standby, but the server is not in recovery (failover?)", %{role: :primary})
  end

  def evaluate(%{mode: "primary", in_recovery: true}, _settings) do
    down("Expected a primary, but the server is in recovery (a standby)", %{role: :standby})
  end

  def evaluate(%{privileged: false, in_recovery: in_recovery}, _settings) do
    down(
      "Insufficient privileges to read the replication status (grant pg_monitor)",
      %{role: if(in_recovery, do: :standby, else: :primary)}
    )
  end

  def evaluate(%{mode: "standby", receiver: receiver}, settings) do
    meta = %{role: :standby, lag_seconds: receiver.lag_seconds, lag_bytes: receiver.lag_bytes}

    case receiver.status do
      nil ->
        down("WAL receiver is not running", meta)

      "streaming" ->
        lag = %{seconds: receiver.lag_seconds || 0.0, bytes: receiver.lag_bytes || 0}
        apply_thresholds("Standby streaming, lag #{format_lag(lag)}", lag, [], settings, meta)

      status ->
        down("WAL receiver is #{status}, not streaming", meta)
    end
  end

  def evaluate(%{mode: "primary", standbys: standbys, inactive_slots: slots}, settings) do
    streaming = Enum.filter(standbys, &(&1.state == "streaming"))
    count = length(streaming)
    min = settings.min_standbys || 1

    lag = %{
      seconds: streaming |> Enum.map(&(&1.replay_lag || 0.0)) |> Enum.max(fn -> 0.0 end),
      bytes: streaming |> Enum.map(&(&1.lag_bytes || 0)) |> Enum.max(fn -> 0 end)
    }

    meta = %{
      role: :primary,
      standbys_streaming: count,
      lag_seconds: lag.seconds,
      lag_bytes: lag.bytes,
      standbys: standbys,
      inactive_slots: slots
    }

    if count < min do
      down("#{count} of #{min} standbys streaming", meta)
    else
      summary =
        if count == 0,
          do: "No standbys streaming",
          else:
            "#{count} #{plural(count, "standby", "standbys")} streaming, max lag #{format_lag(lag)}"

      apply_thresholds(summary, lag, slot_warnings(slots), settings, meta)
    end
  end

  defp slot_warnings(slots) do
    for %{name: name, retained_bytes: retained} <- slots do
      case retained do
        nil -> ~s(replication slot "#{name}" is inactive)
        bytes -> ~s(inactive replication slot "#{name}" retains #{format_bytes(bytes)} of WAL)
      end
    end
  end

  defp apply_thresholds(summary, lag, warnings, settings, meta) do
    seconds = {lag.seconds, settings.lag_warn_seconds, settings.lag_critical_seconds, " s"}
    bytes = {lag.bytes, settings.lag_warn_bytes, settings.lag_critical_bytes, " bytes"}

    critical = Enum.flat_map([seconds, bytes], &exceeded(&1, :critical))
    lag_warnings = Enum.flat_map([seconds, bytes], &exceeded(&1, :warn))

    cond do
      critical != [] ->
        down("#{summary} (#{Enum.join(critical, ", ")})", meta)

      lag_warnings != [] or warnings != [] ->
        message = Enum.join(["Warning: #{summary}" | lag_warnings ++ warnings], "; ")
        {:up, %{message: message, warning: true, meta: meta}}

      true ->
        {:up, %{message: summary, warning: false, meta: meta}}
    end
  end

  defp exceeded({value, warn, _critical, unit}, :warn) when is_integer(warn) and value >= warn,
    do: ["lag reached the warning threshold of #{warn}#{unit}"]

  defp exceeded({value, _warn, critical, unit}, :critical)
       when is_integer(critical) and value >= critical,
       do: ["lag reached the critical threshold of #{critical}#{unit}"]

  defp exceeded(_threshold, _level), do: []

  defp down(message, meta), do: {:down, %{message: message, warning: false, meta: meta}}

  defp format_lag(%{seconds: seconds, bytes: bytes}),
    do: "#{format_seconds(seconds)} (#{format_bytes(bytes)})"

  @doc false
  def format_seconds(seconds) when seconds < 10, do: "#{Float.round(seconds * 1.0, 1)} s"
  def format_seconds(seconds), do: "#{round(seconds)} s"

  @doc false
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  def format_bytes(bytes) do
    {value, unit} =
      Enum.reduce_while(["kB", "MB", "GB", "TB"], {bytes / 1, "B"}, fn unit, {value, _} ->
        value = value / 1024
        if value < 1024 or unit == "TB", do: {:halt, {value, unit}}, else: {:cont, {value, unit}}
      end)

    "#{Float.round(value, 1)} #{unit}"
  end

  defp plural(1, singular, _plural), do: singular
  defp plural(_n, _singular, plural), do: plural
end
