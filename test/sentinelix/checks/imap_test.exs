defmodule Sentinelix.Checks.IMAPTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Checks.IMAP
  alias Sentinelix.Monitoring.Monitor

  doctest IMAP

  # The default test keys are not acceptable for TLS 1.3.
  @key [digest: :sha256, key: {:namedCurve, :secp256r1}]

  @credentials {"monitor@example.com", "s3cret"}

  defp monitor(port, settings, opts \\ []) do
    %Monitor{}
    |> Monitor.changeset(%{
      name: "imap",
      type: :imap,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
      settings: Map.merge(%{host: "localhost", port: port, verify_tls: false}, settings),
      secrets: Keyword.get(opts, :secrets, %{})
    })
    |> Ecto.Changeset.apply_action!(:insert)
  end

  defp login_monitor(port, settings \\ %{}, password \\ "s3cret") do
    monitor(port, Map.put_new(settings, :username, "monitor@example.com"),
      secrets: %{"password" => password}
    )
  end

  defp date_tuple(days), do: Date.utc_today() |> Date.add(days) |> Date.to_erl()

  # A TLS server configuration whose certificate is valid for `days` more.
  defp tls_config(days) do
    %{server_config: config} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: @key ++ [validity: {date_tuple(-400), date_tuple(400)}],
          peer: @key ++ [validity: {date_tuple(-10), date_tuple(days)}]
        },
        client_chain: %{root: [], peer: []}
      })

    config
  end

  ## Fake IMAP server

  # Starts a fake IMAP server and returns its port. Options:
  #
  #   * `:greeting` – the greeting (default "* OK Fake IMAP ready."), or
  #     `:silent` to never send one
  #   * `:capabilities` – CAPABILITY before STARTTLS (default ["IMAP4rev1",
  #     "STARTTLS", "LOGINDISABLED"])
  #   * `:tls_capabilities` – CAPABILITY over TLS (default ["IMAP4rev1",
  #     "AUTH=PLAIN"])
  #   * `:starttls_reply` – replace the reply to STARTTLS
  #   * `:tls` – the server TLS config for STARTTLS and implicit TLS
  #   * `:implicit_tls` – handshake before the greeting
  #   * `:credentials` – the accepted `{username, password}`
  #   * `:mailboxes` – mailbox name => message count (default %{"INBOX" => 42})
  #   * `:bye_on_login_failure` – send BYE and close after a failed login
  defp start_server(opts) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :line,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    test_pid = self()
    opts = opts |> Map.new() |> Map.put(:test_pid, test_pid)

    server = spawn_link(fn -> accept_loop(listen, opts) end)
    on_exit(fn -> Process.exit(server, :kill) end)
    port
  end

  defp accept_loop(listen, opts) do
    {:ok, socket} = :gen_tcp.accept(listen)
    session(socket, opts)
    accept_loop(listen, opts)
  end

  defp session(socket, opts) do
    conn =
      if opts[:implicit_tls] do
        {:ok, ssl} = :ssl.handshake(socket, tls_server_options(opts.tls), 5_000)
        {:ssl, ssl}
      else
        {:gen_tcp, socket}
      end

    case Map.get(opts, :greeting, "* OK Fake IMAP ready.") do
      :silent ->
        Process.sleep(:infinity)

      "* BYE" <> _ = greeting ->
        reply(conn, greeting)
        close(conn)

      greeting ->
        reply(conn, greeting)
        command_loop(conn, opts, opts[:implicit_tls] == true)
    end
  end

  defp tls_server_options(config),
    do: [active: false, packet: :line, mode: :binary, log_level: :none] ++ config

  defp command_loop(conn, opts, tls?) do
    with {:ok, line} <- recv(conn),
         [tag, command] <- String.split(line, " ", parts: 2) do
      {command, conn} = read_literals(command, conn)
      send(opts.test_pid, {:imap, command})
      handle(tag, command, conn, opts, tls?)
    else
      # Closed, or not IMAP (e.g. a TLS handshake).
      _ -> close(conn)
    end
  end

  # Replaces synchronizing literals ({n} at the end of a line) with their
  # contents as quoted strings, so commands can be matched as text.
  defp read_literals(line, conn) do
    case Regex.run(~r/\A(.*)\{(\d+)\}\z/s, line) do
      [_, before, size] ->
        reply(conn, "+ Ready for literal")
        {:ok, rest} = recv(conn)
        size = String.to_integer(size)
        literal = binary_part(rest, 0, size)
        after_literal = binary_part(rest, size, byte_size(rest) - size)
        read_literals(before <> inspect(literal) <> after_literal, conn)

      nil ->
        {line, conn}
    end
  end

  defp handle(tag, "CAPABILITY", conn, opts, tls?) do
    capabilities =
      if tls?,
        do: Map.get(opts, :tls_capabilities, ["IMAP4rev1", "AUTH=PLAIN"]),
        else: Map.get(opts, :capabilities, ["IMAP4rev1", "STARTTLS", "LOGINDISABLED"])

    reply(conn, "* CAPABILITY " <> Enum.join(capabilities, " "))
    reply(conn, "#{tag} OK CAPABILITY completed")
    command_loop(conn, opts, tls?)
  end

  defp handle(tag, "STARTTLS", {:gen_tcp, socket} = conn, opts, false) do
    case Map.get(opts, :starttls_reply, "OK Begin TLS negotiation now") do
      "OK" <> _ = response ->
        reply(conn, "#{tag} #{response}")
        :ok = :inet.setopts(socket, packet: :raw)

        case :ssl.handshake(socket, tls_server_options(opts.tls), 5_000) do
          {:ok, ssl} -> command_loop({:ssl, ssl}, opts, true)
          {:error, _} -> :gen_tcp.close(socket)
        end

      response ->
        reply(conn, "#{tag} #{response}")
        command_loop(conn, opts, false)
    end
  end

  defp handle(tag, "LOGIN " <> args, conn, opts, tls?) do
    {user, " " <> rest} = parse_string(args)
    {pass, ""} = parse_string(rest)
    login_reply(tag, {user, pass}, conn, opts, tls?)
  end

  defp handle(tag, "AUTHENTICATE PLAIN", conn, opts, tls?) do
    reply(conn, "+ ")
    {:ok, token} = recv(conn)
    send(opts.test_pid, {:imap, token})
    [_authzid, user, pass] = token |> Base.decode64!() |> String.split(<<0>>)
    login_reply(tag, {user, pass}, conn, opts, tls?)
  end

  defp handle(tag, "EXAMINE " <> mailbox, conn, opts, tls?) do
    {mailbox, ""} = parse_string(mailbox)

    case Map.fetch(Map.get(opts, :mailboxes, %{"INBOX" => 42}), mailbox) do
      {:ok, count} ->
        reply(conn, "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)")
        reply(conn, "* #{count} EXISTS")
        reply(conn, "* 0 RECENT")
        reply(conn, "#{tag} OK [READ-ONLY] EXAMINE completed")

      :error ->
        reply(conn, "#{tag} NO [NONEXISTENT] Mailbox doesn't exist: #{mailbox}")
    end

    command_loop(conn, opts, tls?)
  end

  defp handle(tag, "LOGOUT", conn, _opts, _tls?) do
    reply(conn, "* BYE Logging out")
    reply(conn, "#{tag} OK Logout completed")
    close(conn)
  end

  defp handle(tag, _command, conn, opts, tls?) do
    reply(conn, "#{tag} BAD Error in IMAP command: Unknown command")
    command_loop(conn, opts, tls?)
  end

  defp login_reply(tag, credentials, conn, opts, tls?) do
    cond do
      credentials == opts[:credentials] ->
        reply(conn, "#{tag} OK Logged in")
        command_loop(conn, opts, tls?)

      opts[:bye_on_login_failure] ->
        reply(conn, "* BYE Too many invalid commands")
        close(conn)

      true ->
        reply(conn, "#{tag} NO [AUTHENTICATIONFAILED] Authentication failed.")
        command_loop(conn, opts, tls?)
    end
  end

  # Parses a quoted string (or an atom) at the start of `args`.
  defp parse_string(~s(") <> rest), do: parse_quoted(rest, "")

  defp parse_string(args) do
    case String.split(args, " ", parts: 2) do
      [atom, rest] -> {atom, " " <> rest}
      [atom] -> {atom, ""}
    end
  end

  defp parse_quoted(~s(\\) <> <<char, rest::binary>>, acc),
    do: parse_quoted(rest, acc <> <<char>>)

  defp parse_quoted(~s(") <> rest, acc), do: {acc, rest}
  defp parse_quoted(<<char, rest::binary>>, acc), do: parse_quoted(rest, acc <> <<char>>)

  defp recv({mod, socket}) do
    with {:ok, line} <- mod.recv(socket, 0, 5_000), do: {:ok, String.trim_trailing(line, "\r\n")}
  end

  defp reply({mod, socket}, line), do: mod.send(socket, line <> "\r\n")
  defp close({mod, socket}), do: mod.close(socket)

  ## Tests

  describe "plain IMAP" do
    test "is up with the greeting text" do
      port = start_server([])

      assert {:up, details} = IMAP.run(monitor(port, %{imap_security: "none"}))
      assert details.message == "Fake IMAP ready."
      assert is_integer(details.response_time_ms)
      refute details[:meta]

      refute_received {:imap, "STARTTLS"}
      refute_received {:imap, "EXAMINE " <> _}
      assert_received {:imap, "LOGOUT"}
    end

    test "is down when the connection is refused" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      assert {:down, %{message: "Connect: connection refused"}} =
               IMAP.run(monitor(port, %{imap_security: "none"}))
    end

    test "is down on a BYE greeting" do
      port = start_server(greeting: "* BYE Too many connections")

      assert {:down, %{message: "Greeting: BYE Too many connections"}} =
               IMAP.run(monitor(port, %{imap_security: "none"}))
    end

    test "is down when the greeting doesn't come in time" do
      port = start_server(greeting: :silent)

      assert {:down, %{message: "Greeting: timed out"}} =
               IMAP.run(monitor(port, %{imap_security: "none"}, timeout_ms: 300))
    end

    test "is down on a greeting that isn't IMAP" do
      port = start_server(greeting: "220 mx.test ESMTP")

      assert {:down, %{message: ~s(Greeting: invalid reply "220 mx.test ESMTP")}} =
               IMAP.run(monitor(port, %{imap_security: "none"}))
    end

    test "logs in and examines the mailbox" do
      port =
        start_server(
          credentials: @credentials,
          capabilities: ["IMAP4rev1"],
          mailboxes: %{"Archive" => 1}
        )

      assert {:up, %{message: "Fake IMAP ready. – Archive: 1 message", meta: %{messages: 1}}} =
               IMAP.run(login_monitor(port, %{imap_security: "none", imap_mailbox: "Archive"}))

      assert_received {:imap, ~s(LOGIN "monitor@example.com" "s3cret")}
      assert_received {:imap, ~s(EXAMINE "Archive")}
    end

    test "examines the mailbox of a pre-authenticated session without logging in" do
      port = start_server(greeting: "* PREAUTH Logged in as monitor")

      assert {:up, %{message: "Logged in as monitor – INBOX: 42 messages"}} =
               IMAP.run(login_monitor(port, %{imap_security: "none"}))

      refute_received {:imap, "LOGIN " <> _}
      assert_received {:imap, ~s(EXAMINE "INBOX")}
    end
  end

  describe "STARTTLS" do
    test "upgrades the connection and evaluates the certificate" do
      port = start_server(tls: tls_config(200))

      assert {:up, details} = IMAP.run(monitor(port, %{imap_security: "starttls"}))
      assert details.message =~ ~r/^Fake IMAP ready\. – Certificate valid for (199|200) days/
      assert details.meta.days_remaining in 199..200

      assert_received {:imap, "CAPABILITY"}
      assert_received {:imap, "STARTTLS"}
      assert_received {:imap, "LOGOUT"}
    end

    test "uses the capabilities of the greeting, without showing them" do
      port =
        start_server(
          tls: tls_config(200),
          greeting: "* OK [CAPABILITY IMAP4rev1 STARTTLS] Fake IMAP ready."
        )

      assert {:up, %{message: "Fake IMAP ready. – Certificate valid" <> _}} =
               IMAP.run(monitor(port, %{imap_security: "starttls"}))

      refute_received {:imap, "CAPABILITY"}
      assert_received {:imap, "STARTTLS"}
    end

    test "is down when STARTTLS is not advertised" do
      port = start_server(capabilities: ["IMAP4rev1"])

      assert {:down, %{message: "STARTTLS: not advertised by the server"}} =
               IMAP.run(monitor(port, %{imap_security: "starttls"}))

      refute_received {:imap, "STARTTLS"}
    end

    test "is down when STARTTLS is refused" do
      port = start_server(starttls_reply: "BAD STARTTLS not available")

      assert {:down, %{message: "STARTTLS: BAD STARTTLS not available"}} =
               IMAP.run(monitor(port, %{imap_security: "starttls"}))
    end

    test "is down when the certificate can't be verified" do
      port = start_server(tls: tls_config(200))

      assert {:down, %{message: "TLS handshake: " <> reason}} =
               IMAP.run(monitor(port, %{imap_security: "starttls", verify_tls: true}))

      assert reason =~ ~r/unknown ca/i
    end

    test "asks for the capabilities again after STARTTLS and logs in" do
      port = start_server(tls: tls_config(200), credentials: @credentials)

      assert {:up, %{message: message, meta: %{messages: 42, days_remaining: _}}} =
               IMAP.run(login_monitor(port, %{imap_security: "starttls"}))

      assert message =~ ~r/^Fake IMAP ready\. – INBOX: 42 messages – Certificate valid/

      assert_received {:imap, "CAPABILITY"}
      assert_received {:imap, "STARTTLS"}
      assert_received {:imap, "CAPABILITY"}
      assert_received {:imap, ~s(LOGIN "monitor@example.com" "s3cret")}
    end
  end

  describe "implicit TLS" do
    test "handshakes before the greeting" do
      port = start_server(tls: tls_config(200), implicit_tls: true)

      assert {:up, %{message: message, meta: %{days_remaining: _}}} =
               IMAP.run(monitor(port, %{}))

      assert message =~ "Fake IMAP ready. – Certificate valid"
      refute_received {:imap, "STARTTLS"}
    end

    test "is down when the server doesn't speak TLS" do
      port = start_server([])

      assert {:down, %{message: "TLS handshake: " <> _}} = IMAP.run(monitor(port, %{}))
    end

    test "warns when the certificate expires within cert_warn_days" do
      port = start_server(tls: tls_config(20), implicit_tls: true)

      assert {:up, %{warning: true, message: message, meta: %{days_remaining: days}}} =
               IMAP.run(monitor(port, %{}))

      assert message =~ "Fake IMAP ready. – Warning: certificate expires in"
      assert days in 19..20
    end

    test "is down when the certificate expires within cert_critical_days" do
      port = start_server(tls: tls_config(3), implicit_tls: true)

      assert {:down, %{message: "Certificate expires in " <> _, meta: %{days_remaining: _}}} =
               IMAP.run(monitor(port, %{}))
    end
  end

  describe "login" do
    setup do
      %{port: start_server(tls: tls_config(200), implicit_tls: true, credentials: @credentials)}
    end

    test "is up with valid credentials and the message count", %{port: port} do
      assert {:up, %{message: message, meta: %{messages: 42, days_remaining: _}}} =
               IMAP.run(login_monitor(port))

      assert message =~ "Fake IMAP ready. – INBOX: 42 messages – Certificate valid"
      assert_received {:imap, "CAPABILITY"}
      assert_received {:imap, ~s(LOGIN "monitor@example.com" "s3cret")}
      assert_received {:imap, ~s(EXAMINE "INBOX")}
      assert_received {:imap, "LOGOUT"}
    end

    test "is down with invalid credentials, keeping the certificate meta", %{port: port} do
      assert {:down, %{message: message, meta: %{days_remaining: _}}} =
               IMAP.run(login_monitor(port, %{}, "wrong"))

      assert message == "LOGIN: NO [AUTHENTICATIONFAILED] Authentication failed."
      refute_received {:imap, "EXAMINE " <> _}
    end

    test "is down when the mailbox doesn't exist", %{port: port} do
      assert {:down, %{message: "EXAMINE Nope: NO [NONEXISTENT] Mailbox doesn't exist: Nope"}} =
               IMAP.run(login_monitor(port, %{imap_mailbox: "Nope"}))
    end

    test "quotes special characters" do
      credentials = {~s(mon"itor), ~s(s3\\cret)}
      port = start_server(credentials: credentials, capabilities: ["IMAP4rev1"])

      assert {:up, _} =
               IMAP.run(
                 login_monitor(
                   port,
                   %{imap_security: "none", username: ~s(mon"itor)},
                   ~s(s3\\cret)
                 )
               )

      assert_received {:imap, ~S(LOGIN "mon\"itor" "s3\\cret")}
    end

    test "sends 8-bit credentials as literals" do
      credentials = {"monitor@example.com", "pässwörd"}
      port = start_server(credentials: credentials, capabilities: ["IMAP4rev1"])

      assert {:up, _} =
               IMAP.run(login_monitor(port, %{imap_security: "none"}, "pässwörd"))

      assert_received {:imap, ~s(LOGIN "monitor@example.com" "pässwörd")}
    end

    test "encodes the mailbox name in modified UTF-7" do
      port =
        start_server(
          credentials: @credentials,
          capabilities: ["IMAP4rev1"],
          mailboxes: %{"Entw&APw-rfe" => 3}
        )

      assert {:up, %{message: "Fake IMAP ready. – Entwürfe: 3 messages"}} =
               IMAP.run(login_monitor(port, %{imap_security: "none", imap_mailbox: "Entwürfe"}))
    end

    test "uses AUTHENTICATE PLAIN when LOGIN is disabled" do
      port =
        start_server(
          credentials: @credentials,
          capabilities: ["IMAP4rev1", "LOGINDISABLED", "AUTH=PLAIN"]
        )

      assert {:up, %{meta: %{messages: 42}}} =
               IMAP.run(login_monitor(port, %{imap_security: "none"}))

      assert_received {:imap, "CAPABILITY"}
      assert_received {:imap, "AUTHENTICATE PLAIN"}
      assert_received {:imap, token}
      assert Base.decode64!(token) == "\0monitor@example.com\0s3cret"
      refute_received {:imap, "LOGIN " <> _}
    end

    test "is down with invalid credentials over AUTHENTICATE PLAIN" do
      port =
        start_server(
          credentials: @credentials,
          capabilities: ["IMAP4rev1", "LOGINDISABLED", "AUTH=PLAIN"]
        )

      assert {:down, %{message: "AUTHENTICATE: NO [AUTHENTICATIONFAILED] Authentication failed."}} =
               IMAP.run(login_monitor(port, %{imap_security: "none"}, "wrong"))
    end

    test "is down when LOGIN is disabled and AUTHENTICATE PLAIN isn't offered" do
      port = start_server(credentials: @credentials)

      assert {:down, %{message: "LOGIN: disabled by the server (LOGINDISABLED) " <> _}} =
               IMAP.run(login_monitor(port, %{imap_security: "none"}))

      refute_received {:imap, "LOGIN " <> _}
    end

    test "reports the BYE of a server that closes the connection" do
      port =
        start_server(
          credentials: @credentials,
          capabilities: ["IMAP4rev1"],
          bye_on_login_failure: true
        )

      assert {:down, %{message: "LOGIN: BYE Too many invalid commands"}} =
               IMAP.run(login_monitor(port, %{imap_security: "none"}, "wrong"))
    end
  end
end
