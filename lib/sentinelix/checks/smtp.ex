defmodule Sentinelix.Checks.SMTP do
  @moduledoc """
  SMTP check: speaks SMTP to a mail server instead of only checking that
  its port is open. No mail is sent.

  ## Check flow

    1. Connect over TCP (or TLS, with `smtp_security: "tls"`), expect a
       `220` greeting.
    2. `EHLO`, expect `250`.
    3. With `smtp_security: "starttls"` (the default): `STARTTLS` must be
       advertised in the `EHLO` reply – a stripped or misconfigured STARTTLS
       is `:down` – then the connection is upgraded and `EHLO` sent again.
    4. With a `username`: `AUTH` (`PLAIN`, or `LOGIN` if the server doesn't
       offer `PLAIN`) with the monitor's `password` secret, expect `235`.
    5. `QUIT`.

  The result is `:up` with the greeting banner, or `:down` with the failing
  step and the server's reply (e.g. `STARTTLS: 454 TLS not available`).

  ## TLS

  TLS connections send SNI and, with `verify_tls` (the default), verify the
  certificate chain against the system CAs and the hostname (IP addresses
  are not checked against the certificate). The peer certificate's expiry
  is then evaluated like `Sentinelix.Checks.Cert` does, with the monitor's
  `cert_warn_days` and `cert_critical_days`, so one monitor covers both the
  service and its certificate: a certificate close to expiry raises a
  warning, one within `cert_critical_days` (or expired) is `:down`. The
  remaining days are passed on as `meta: %{days_remaining: n, expires_at:
  datetime}`.
  """

  @behaviour Sentinelix.Checks.Check

  alias Sentinelix.Checks.{Cert, TCP}
  alias Sentinelix.Monitoring.{Monitor, Settings}

  # A multiline reply with more lines than this is treated as an error.
  @max_reply_lines 100

  @impl true
  def run(%Monitor{settings: %Settings{} = settings, timeout_ms: timeout} = monitor) do
    started = System.monotonic_time()
    deadline = System.monotonic_time(:millisecond) + timeout
    result = probe(settings, Monitor.secret(monitor, "password"), deadline)

    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    {status, details} = evaluate(result, settings, DateTime.utc_now())
    {status, Map.put(details, :response_time_ms, elapsed_ms)}
  end

  @doc """
  The default name sent in `EHLO`: the host of Sentinelix' public URL, or
  the machine's hostname when that isn't configured.
  """
  @spec default_ehlo_name() :: String.t()
  def default_ehlo_name do
    url = :sentinelix |> Application.get_env(SentinelixWeb.Endpoint, []) |> Keyword.get(:url, [])

    case url[:host] do
      host when is_binary(host) and host not in ["", "localhost"] ->
        host

      _ ->
        {:ok, hostname} = :inet.gethostname()
        to_string(hostname)
    end
  end

  ## Evaluation

  defp evaluate({:ok, conn}, settings, now) do
    case conn.cert do
      nil ->
        {:up, %{message: conn.banner}}

      der ->
        case Cert.evaluate_der(der, settings, now) do
          {:up, details} -> {:up, %{details | message: "#{conn.banner} – #{details.message}"}}
          {:down, details} -> {:down, details}
        end
    end
  end

  defp evaluate({:error, conn, message}, settings, now) do
    details = %{message: message}

    with %{cert: der} when is_binary(der) <- conn,
         {_status, %{meta: meta}} <- Cert.evaluate_der(der, settings, now) do
      {:down, Map.put(details, :meta, meta)}
    else
      _ -> {:down, details}
    end
  end

  ## Session

  defp probe(settings, password, deadline) do
    case TCP.open(settings.host, settings.port, remaining(deadline), packet: :line) do
      {:ok, socket} ->
        conn = %{
          mod: :gen_tcp,
          socket: socket,
          host: settings.host,
          settings: settings,
          password: password,
          deadline: deadline,
          banner: nil,
          extensions: %{},
          cert: nil
        }

        result = run_steps(steps(settings), conn)
        close(elem(result, 1))
        result

      {:error, reason} ->
        {:error, nil, "Connect: #{format_error(reason)}"}
    end
  end

  defp steps(%Settings{smtp_security: security, username: username}) do
    [
      if(security == "tls", do: &upgrade/1),
      &greeting/1,
      &ehlo/1,
      if(security == "starttls", do: &starttls/1),
      if(is_binary(username), do: &auth/1),
      &quit/1
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp run_steps([], conn), do: {:ok, conn}

  defp run_steps([step | steps], conn) do
    case step.(conn) do
      {:ok, conn} -> run_steps(steps, conn)
      {:error, _conn, _message} = error -> error
    end
  end

  defp greeting(conn) do
    case read_reply(conn) do
      {:ok, 220, [first | _]} ->
        banner = with "" <- reply_text(first), do: "Connected"
        {:ok, %{conn | banner: banner}}

      {:ok, _code, lines} ->
        {:error, conn, "Greeting: #{List.last(lines)}"}

      {:error, reason} ->
        {:error, conn, "Greeting: #{format_error(reason)}"}
    end
  end

  defp ehlo(conn) do
    with {:ok, lines} <- command(conn, "EHLO #{ehlo_name(conn.settings)}", "EHLO", 250) do
      {:ok, %{conn | extensions: extensions(lines)}}
    end
  end

  defp starttls(conn) do
    if Map.has_key?(conn.extensions, "STARTTLS") do
      with {:ok, _lines} <- command(conn, "STARTTLS", "STARTTLS", 220),
           {:ok, conn} <- upgrade(conn) do
        ehlo(conn)
      end
    else
      {:error, conn, "STARTTLS: not advertised by the server"}
    end
  end

  defp upgrade(%{mod: :gen_tcp, socket: socket} = conn) do
    host = String.to_charlist(conn.host)
    # TLS records aren't lines.
    :ok = :inet.setopts(socket, packet: :raw)

    case :ssl.connect(socket, tls_options(host, conn.settings), remaining(conn.deadline)) do
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

  defp tls_options(host, %Settings{verify_tls: verify?}) do
    sni = Cert.server_name_indication(host)

    verify =
      if verify? == false do
        [verify: :verify_none]
      else
        [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      end

    [
      server_name_indication: sni,
      mode: :binary,
      active: false,
      packet: :line,
      # Failures are reported in the result, don't log every TLS alert.
      log_level: :error
    ] ++ verify
  end

  defp auth(conn) do
    case Map.get(conn.extensions, "AUTH") do
      nil -> {:error, conn, "AUTH: not offered by the server"}
      mechanisms -> auth(conn, mechanisms, conn.settings.username, conn.password || "")
    end
  end

  defp auth(conn, mechanisms, username, password) do
    cond do
      "PLAIN" in mechanisms ->
        token = Base.encode64(<<0, username::binary, 0, password::binary>>)
        auth_result(command(conn, "AUTH PLAIN #{token}", "AUTH", 235), conn)

      "LOGIN" in mechanisms ->
        with {:ok, _} <- command(conn, "AUTH LOGIN", "AUTH", 334),
             {:ok, _} <- command(conn, Base.encode64(username), "AUTH", 334) do
          auth_result(command(conn, Base.encode64(password), "AUTH", 235), conn)
        end

      true ->
        {:error, conn, "AUTH: neither PLAIN nor LOGIN offered (#{Enum.join(mechanisms, " ")})"}
    end
  end

  defp auth_result({:ok, _lines}, conn), do: {:ok, conn}
  defp auth_result(error, _conn), do: error

  # The server's reply to QUIT doesn't matter: everything has been checked.
  defp quit(conn) do
    _ = command(conn, "QUIT", "QUIT", 221)
    {:ok, conn}
  end

  defp close(nil), do: :ok
  defp close(%{mod: mod, socket: socket}), do: mod.close(socket)

  ## Protocol

  # Sends `line` and reads the reply, which must have the `expected` code.
  defp command(conn, line, step, expected) do
    with :ok <- send_line(conn, line),
         {:ok, ^expected, lines} <- read_reply(conn) do
      {:ok, lines}
    else
      {:ok, _code, lines} -> {:error, conn, "#{step}: #{List.last(lines)}"}
      {:error, reason} -> {:error, conn, "#{step}: #{format_error(reason)}"}
    end
  end

  defp send_line(%{mod: mod, socket: socket}, line), do: mod.send(socket, [line, "\r\n"])

  # Reads a (multiline) reply: `250-first`, `250-second`, `250 last`.
  defp read_reply(conn, lines \\ []) do
    with {:ok, data} <- conn.mod.recv(conn.socket, 0, remaining(conn.deadline)) do
      line = String.trim_trailing(data)
      lines = [line | lines]

      case parse_reply_line(line) do
        :more when length(lines) < @max_reply_lines -> read_reply(conn, lines)
        {:last, code} -> {:ok, code, Enum.reverse(lines)}
        _ -> {:error, {:bad_reply, line}}
      end
    end
  end

  defp parse_reply_line(<<code::binary-3, rest::binary>>) do
    case {integer_code(code), rest} do
      {nil, _rest} -> :error
      {_code, "-" <> _} -> :more
      {code, ""} -> {:last, code}
      {code, " " <> _} -> {:last, code}
      _ -> :error
    end
  end

  defp parse_reply_line(_line), do: :error

  defp integer_code(code) do
    case Integer.parse(code) do
      {code, ""} when code in 100..599 -> code
      _ -> nil
    end
  end

  # The text of a reply line, without the code and separator.
  defp reply_text(<<_code::binary-3, _separator, rest::binary>>), do: String.trim(rest)
  defp reply_text(_line), do: ""

  # EHLO keywords => parameters, e.g. %{"AUTH" => ["PLAIN", "LOGIN"]}. The
  # first line is the greeting.
  defp extensions([_greeting | lines]) do
    for line <- lines,
        [keyword | params] <- [line |> reply_text() |> String.upcase() |> String.split()],
        into: %{},
        do: {keyword, params}
  end

  defp extensions([]), do: %{}

  defp ehlo_name(%Settings{smtp_ehlo_name: name}) do
    name = name || default_ehlo_name()

    # IP addresses are sent as address literals (RFC 5321, 4.1.3).
    case :inet.parse_strict_address(String.to_charlist(name)) do
      {:ok, ip} when tuple_size(ip) == 4 -> "[#{name}]"
      {:ok, _ip} -> "[IPv6:#{name}]"
      {:error, _} -> name
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp format_error(:closed), do: "connection closed"
  defp format_error({:bad_reply, line}), do: "invalid reply #{inspect(line)}"
  defp format_error(reason), do: Cert.format_error(reason)
end
