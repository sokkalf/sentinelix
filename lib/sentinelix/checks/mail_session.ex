defmodule Sentinelix.Checks.MailSession do
  @moduledoc """
  Connection helpers shared by the line based mail protocol checks
  (`Sentinelix.Checks.SMTP`, `Sentinelix.Checks.IMAP`, and
  `Sentinelix.Checks.StartTLS` for certificate monitors): connecting over TCP,
  upgrading to TLS (implicit TLS or STARTTLS), sending and receiving lines
  within the monitor's timeout, running the protocol steps and evaluating
  the peer certificate's expiry with `Sentinelix.Checks.Cert`.

  A session (`t:conn/0`) is a map with the socket, the deadline and the peer
  certificate; checks add their own protocol state to it (see `open/3`).
  Protocol steps take a session and return `{:ok, conn}` or `{:error, conn,
  message}`, the message naming the failing step and the server's reply.

  ## TLS

  TLS connections send SNI and, with `verify_tls` (the default), verify the
  certificate chain against the system CAs and the hostname (IP addresses
  are not checked against the certificate). The peer certificate's expiry
  is then evaluated with the monitor's `cert_warn_days` and
  `cert_critical_days`, so one monitor covers both the service and its
  certificate: a certificate close to expiry raises a warning, one within
  `cert_critical_days` (or expired) is `:down`. The remaining days are
  passed on as `meta: %{days_remaining: n, expires_at: datetime}`.
  """

  alias Sentinelix.Checks.{Cert, TCP}
  alias Sentinelix.Monitoring.{Monitor, Settings}

  @type conn :: %{
          required(:mod) => :gen_tcp | :ssl,
          required(:socket) => term(),
          required(:host) => String.t(),
          required(:settings) => Settings.t(),
          required(:deadline) => integer(),
          required(:cert) => binary() | nil,
          optional(atom()) => term()
        }

  @type step_result :: {:ok, conn()} | {:error, conn() | nil, String.t()}

  @doc """
  Runs `probe` (a function of the deadline returning `{:ok, conn, details}`
  or `{:error, conn, message}`) within the monitor's timeout and evaluates
  its result with `evaluate/3`, adding the response time.
  """
  @spec run(Monitor.t(), (integer() -> term())) :: Sentinelix.Checks.Check.result()
  def run(%Monitor{settings: %Settings{} = settings, timeout_ms: timeout}, probe) do
    started = System.monotonic_time()
    result = probe.(System.monotonic_time(:millisecond) + timeout)

    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    {status, details} = evaluate(result, settings, DateTime.utc_now())
    {status, Map.put(details, :response_time_ms, elapsed_ms)}
  end

  @doc """
  Connects to the settings' `host:port` in line mode. `state` is the
  check's own protocol state, merged into the session.
  """
  @spec open(Settings.t(), integer(), map()) :: {:ok, conn()} | {:error, nil, String.t()}
  def open(%Settings{} = settings, deadline, state \\ %{}) do
    case TCP.open(settings.host, settings.port, remaining(deadline), packet: :line) do
      {:ok, socket} ->
        conn = %{
          mod: :gen_tcp,
          socket: socket,
          host: settings.host,
          settings: settings,
          deadline: deadline,
          cert: nil
        }

        {:ok, Map.merge(state, conn)}

      {:error, reason} ->
        {:error, nil, "Connect: #{format_error(reason)}"}
    end
  end

  @doc """
  Runs the protocol `steps` in order, stopping at the first error, and
  closes the connection.
  """
  @spec run_steps([(conn() -> step_result())], conn()) :: step_result()
  def run_steps(steps, conn) do
    result = do_run_steps(steps, conn)
    close(elem(result, 1))
    result
  end

  defp do_run_steps([], conn), do: {:ok, conn}

  defp do_run_steps([step | steps], conn) do
    case step.(conn) do
      {:ok, conn} -> do_run_steps(steps, conn)
      {:error, _conn, _message} = error -> error
    end
  end

  @doc """
  Upgrades a plain connection to TLS (for implicit TLS, or after the
  server accepted STARTTLS) and remembers the peer certificate.

  ## Options

    * `:verify` – whether to verify the certificate chain and hostname
      (default: the settings' `verify_tls`, `true` unless it is `false`)
  """
  @spec upgrade(conn(), keyword()) :: step_result()
  def upgrade(%{mod: :gen_tcp, socket: socket} = conn, opts \\ []) do
    host = String.to_charlist(conn.host)
    verify? = Keyword.get_lazy(opts, :verify, fn -> conn.settings.verify_tls != false end)
    # TLS records aren't lines.
    :ok = :inet.setopts(socket, packet: :raw)

    case :ssl.connect(socket, tls_options(host, verify?), remaining(conn.deadline)) do
      {:ok, ssl} ->
        cert =
          case :ssl.peercert(ssl) do
            {:ok, der} -> der
            {:error, _} -> nil
          end

        {:ok, %{conn | mod: :ssl, socket: ssl, cert: cert}}

      {:error, reason} ->
        {:error, conn, "TLS handshake: #{format_error(reason)}"}
    end
  end

  defp tls_options(host, verify?) do
    verify =
      if verify? do
        [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      else
        [verify: :verify_none]
      end

    [
      server_name_indication: Cert.server_name_indication(host),
      mode: :binary,
      active: false,
      packet: :line,
      # Failures are reported in the result, don't log every TLS alert.
      log_level: :error
    ] ++ verify
  end

  @doc "Closes the session's socket (if any)."
  @spec close(conn() | nil) :: :ok
  def close(nil), do: :ok

  def close(%{mod: mod, socket: socket}) do
    _ = mod.close(socket)
    :ok
  end

  @doc "Sends `line` followed by CRLF."
  @spec send_line(conn(), iodata()) :: :ok | {:error, term()}
  def send_line(%{mod: mod, socket: socket}, line), do: mod.send(socket, [line, "\r\n"])

  @doc "Receives a line (without the line ending) before the deadline."
  @spec recv_line(conn()) :: {:ok, String.t()} | {:error, term()}
  def recv_line(%{mod: mod, socket: socket, deadline: deadline}) do
    with {:ok, data} <- mod.recv(socket, 0, remaining(deadline)) do
      {:ok, String.trim_trailing(data)}
    end
  end

  @doc """
  Evaluates a probe result: `{:ok, conn, details}` is `:up` with `details`
  (`message` and optionally `meta`), combined with the evaluation of the
  peer certificate for TLS sessions; `{:error, conn, message}` is `:down`,
  still with the certificate's `meta` when there is one.
  """
  @spec evaluate(
          {:ok, conn(), map()} | {:error, conn() | nil, String.t()},
          Settings.t(),
          DateTime.t()
        ) :: Sentinelix.Checks.Check.result()
  def evaluate({:ok, %{cert: nil}, details}, _settings, _now), do: {:up, details}

  def evaluate({:ok, %{cert: der}, details}, settings, now) do
    {status, cert} = Cert.evaluate_der(der, settings, now)
    cert = merge_meta(cert, details[:meta])

    case status do
      :up -> {:up, %{cert | message: "#{details.message} – #{cert.message}"}}
      :down -> {:down, cert}
    end
  end

  def evaluate({:error, conn, message}, settings, now) do
    details = %{message: message}

    with %{cert: der} when is_binary(der) <- conn,
         {_status, %{meta: meta}} <- Cert.evaluate_der(der, settings, now) do
      {:down, Map.put(details, :meta, meta)}
    else
      _ -> {:down, details}
    end
  end

  defp merge_meta(details, nil), do: details
  defp merge_meta(details, meta), do: Map.update(details, :meta, meta, &Map.merge(meta, &1))

  @doc "The milliseconds left until `deadline` (at least 0)."
  @spec remaining(integer()) :: non_neg_integer()
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc "A readable description of a connection or protocol error."
  @spec format_error(term()) :: String.t()
  def format_error(:closed), do: "connection closed"
  def format_error({:bad_reply, line}), do: "invalid reply #{inspect(line)}"
  def format_error(reason), do: Cert.format_error(reason)
end
