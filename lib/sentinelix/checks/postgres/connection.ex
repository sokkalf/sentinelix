defmodule Sentinelix.Checks.Postgres.Connection do
  @moduledoc """
  A one-shot PostgreSQL connection owned by the calling process.

  The PostgreSQL check deliberately opens a fresh connection per check:
  that a new login works is part of what is being monitored. A regular
  `Postgrex.start_link/1` pool is a poor fit for that: its connection
  process retries failed connects with backoff (or, with `backoff_type:
  :stop`, crashes) and the caller only sees a vague checkout error, while
  the actual reason ("password authentication failed …") is only logged.

  Instead, this module drives Postgrex' `DBConnection` implementation
  (`Postgrex.Protocol`) directly from the calling process – which is what
  a `DBConnection` pool would do in its connection process:

    * `connect/1` returns the server's error synchronously and logs
      nothing.
    * No processes are started. The socket belongs to the caller, so when
      the check task is killed (e.g. on timeout) the connection is closed
      with it; nothing can leak.

  `Postgrex.Protocol` is not a documented module, but it implements the
  documented `DBConnection` behaviour, which is all this module relies on.
  The tests in `Sentinelix.Checks.PostgresTest` run against a real server
  and would catch a breaking change on a Postgrex upgrade.
  """

  alias Postgrex.Protocol

  @opaque t :: %{state: term(), opts: keyword()}

  @doc """
  Connects and authenticates.

  `opts` are Postgrex connection options (`:hostname`, `:port`,
  `:database`, `:username`, `:password`, `:ssl`, `:parameters`,
  `:timeout`, `:connect_timeout`, …). Unlike `Postgrex.start_link/1`, no
  defaults are taken from `PG*` environment variables.
  """
  @spec connect(keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def connect(opts) do
    opts = Keyword.merge([types: Postgrex.DefaultTypes, prepare: :unnamed], opts)

    # `Protocol.connect/1` traps exits for the benefit of DBConnection's
    # connection process. The caller is a plain check task that must stay
    # killable, so the flag is restored afterwards.
    trap_exit = Process.flag(:trap_exit, false)

    try do
      case Protocol.connect(opts) do
        # The options are passed on to queries, which don't need the password.
        {:ok, state} -> {:ok, %{state: state, opts: Keyword.delete(opts, :password)}}
        {:error, error} -> {:error, error}
      end
    rescue
      # Raised exceptions may contain the options (and with them the
      # password), so they are never passed on as they are.
      error in KeyError ->
        if error.key == :password,
          do: {:error, Postgrex.Error.exception(message: "the server requires a password")},
          else: {:error, unexpected_error(error)}

      error ->
        {:error, unexpected_error(error)}
    after
      Process.flag(:trap_exit, trap_exit)
    end
  end

  defp unexpected_error(%module{}),
    do: RuntimeError.exception("unexpected error (#{inspect(module)})")

  @doc """
  Runs a query (a single statement) and returns its result.

  The connection must not be used anymore after an error.
  """
  @spec query(t(), String.t(), list()) ::
          {:ok, Postgrex.Result.t(), t()} | {:error, Exception.t(), t()}
  def query(%{state: state, opts: opts} = conn, statement, params \\ []) do
    query = DBConnection.Query.parse(%Postgrex.Query{name: "", statement: statement}, opts)

    with {:ok, query, state} <- prepare(query, opts, state),
         query = DBConnection.Query.describe(query, opts),
         params = DBConnection.Query.encode(query, params, opts),
         {:ok, query, result, state} <- execute(query, params, opts, state) do
      {:ok, DBConnection.Query.decode(query, result, opts), %{conn | state: state}}
    else
      {:error, error, state} -> {:error, error, %{conn | state: state}}
    end
  rescue
    error in [DBConnection.EncodeError, ArgumentError] -> {:error, error, conn}
  end

  defp prepare(query, opts, state) do
    case Protocol.handle_prepare(query, opts, state) do
      {:ok, query, state} -> {:ok, query, state}
      {_error_or_disconnect, error, state} -> {:error, error, state}
    end
  end

  defp execute(query, params, opts, state) do
    case Protocol.handle_execute(query, params, opts, state) do
      {:ok, query, result, state} -> {:ok, query, result, state}
      {_error_or_disconnect, error, state} -> {:error, error, state}
    end
  end

  @doc """
  Closes the connection (sends a `Terminate` message and closes the
  socket).
  """
  @spec close(t()) :: :ok
  def close(%{state: state}) do
    # Without a cancel key, disconnect doesn't open a second connection to
    # cancel a running query: there is none, every query has completed.
    state = Map.replace(state, :connection_key, nil)
    Protocol.disconnect(%DBConnection.ConnectionError{message: "closed"}, state)
  catch
    # The socket may already be gone; there is nothing left to clean up.
    _kind, _reason -> :ok
  end
end
