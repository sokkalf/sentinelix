defmodule Sentinelix.Checks.SMTPTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Checks.SMTP
  alias Sentinelix.Monitoring.Monitor

  # The default test keys are not acceptable for TLS 1.3.
  @key [digest: :sha256, key: {:namedCurve, :secp256r1}]

  defp monitor(port, settings, opts \\ []) do
    %Monitor{}
    |> Monitor.changeset(%{
      name: "mail",
      type: :smtp,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
      settings:
        Map.merge(
          %{host: "localhost", port: port, verify_tls: false, smtp_ehlo_name: "probe.example"},
          settings
        ),
      secrets: Keyword.get(opts, :secrets, %{})
    })
    |> Ecto.Changeset.apply_action!(:insert)
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

  ## Fake SMTP server

  # Starts a fake SMTP server and returns its port. Options:
  #
  #   * `:greeting` – the greeting (default "220 mx.test ESMTP Fake"), or
  #     `:silent` to never send one
  #   * `:extensions` – EHLO keywords before STARTTLS (default ["STARTTLS",
  #     "AUTH PLAIN LOGIN"])
  #   * `:tls_extensions` – EHLO keywords after STARTTLS (default ["AUTH PLAIN LOGIN"])
  #   * `:ehlo_reply`, `:starttls_reply` – replace the reply to EHLO / STARTTLS
  #   * `:tls` – the server TLS config for STARTTLS and implicit TLS
  #   * `:implicit_tls` – handshake before the greeting
  #   * `:credentials` – the accepted `{username, password}`
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
    opts = Map.new(opts)

    server = spawn_link(fn -> accept_loop(listen, opts, test_pid) end)
    on_exit(fn -> Process.exit(server, :kill) end)
    port
  end

  defp accept_loop(listen, opts, test_pid) do
    {:ok, socket} = :gen_tcp.accept(listen)
    session(socket, opts, test_pid)
    accept_loop(listen, opts, test_pid)
  end

  defp session(socket, opts, test_pid) do
    conn =
      if opts[:implicit_tls] do
        {:ok, ssl} = :ssl.handshake(socket, tls_server_options(opts.tls), 5_000)
        {:ssl, ssl}
      else
        {:gen_tcp, socket}
      end

    case Map.get(opts, :greeting, "220 mx.test ESMTP Fake") do
      :silent ->
        Process.sleep(:infinity)

      greeting ->
        reply(conn, greeting)
        command_loop(conn, opts, test_pid, opts[:implicit_tls] == true)
    end
  end

  defp tls_server_options(config),
    do: [active: false, packet: :line, mode: :binary, log_level: :none] ++ config

  defp command_loop({mod, socket} = conn, opts, test_pid, tls?) do
    case mod.recv(socket, 0, 5_000) do
      {:ok, line} ->
        line = String.trim_trailing(line)
        send(test_pid, {:smtp, line})
        handle(line, conn, opts, test_pid, tls?)

      {:error, _} ->
        mod.close(socket)
    end
  end

  defp handle("EHLO " <> _name, conn, opts, test_pid, tls?) do
    extensions =
      if tls?,
        do: Map.get(opts, :tls_extensions, ["AUTH PLAIN LOGIN"]),
        else: Map.get(opts, :extensions, ["STARTTLS", "AUTH PLAIN LOGIN"])

    case opts[:ehlo_reply] do
      nil ->
        reply(conn, ["250-mx.test Hello" | Enum.map(extensions, &"250-#{&1}")], "250 8BITMIME")

      line ->
        reply(conn, line)
    end

    command_loop(conn, opts, test_pid, tls?)
  end

  defp handle("STARTTLS", {:gen_tcp, socket} = conn, opts, test_pid, false) do
    case Map.get(opts, :starttls_reply, "220 Go ahead") do
      "220" <> _ = line ->
        reply(conn, line)
        :ok = :inet.setopts(socket, packet: :raw)

        case :ssl.handshake(socket, tls_server_options(opts.tls), 5_000) do
          {:ok, ssl} -> command_loop({:ssl, ssl}, opts, test_pid, true)
          {:error, _} -> :gen_tcp.close(socket)
        end

      line ->
        reply(conn, line)
        command_loop(conn, opts, test_pid, false)
    end
  end

  defp handle("AUTH PLAIN " <> token, conn, opts, test_pid, tls?) do
    [_authzid, user, pass] = token |> Base.decode64!() |> String.split(<<0>>)
    auth_reply(conn, opts, {user, pass})
    command_loop(conn, opts, test_pid, tls?)
  end

  defp handle("AUTH LOGIN", {mod, socket} = conn, opts, test_pid, tls?) do
    reply(conn, "334 VXNlcm5hbWU6")
    {:ok, user} = mod.recv(socket, 0, 5_000)
    reply(conn, "334 UGFzc3dvcmQ6")
    {:ok, pass} = mod.recv(socket, 0, 5_000)
    decode = &(&1 |> String.trim_trailing() |> Base.decode64!())
    auth_reply(conn, opts, {decode.(user), decode.(pass)})
    command_loop(conn, opts, test_pid, tls?)
  end

  defp handle("QUIT", {mod, socket} = conn, _opts, _test_pid, _tls?) do
    reply(conn, "221 Bye")
    mod.close(socket)
  end

  defp handle(_line, conn, opts, test_pid, tls?) do
    reply(conn, "502 5.5.2 Command not recognized")
    command_loop(conn, opts, test_pid, tls?)
  end

  defp auth_reply(conn, opts, credentials) do
    if credentials == opts[:credentials],
      do: reply(conn, "235 2.7.0 Authentication successful"),
      else: reply(conn, "535 5.7.8 Authentication credentials invalid")
  end

  defp reply(conn, lines, last), do: reply(conn, Enum.join(lines, "\r\n") <> "\r\n" <> last)
  defp reply({mod, socket}, line), do: mod.send(socket, line <> "\r\n")

  ## Tests

  describe "plain SMTP" do
    test "is up with the greeting banner" do
      port = start_server([])

      assert {:up, details} = SMTP.run(monitor(port, %{smtp_security: "none"}))
      assert details.message == "mx.test ESMTP Fake"
      assert is_integer(details.response_time_ms)
      refute details[:meta]

      assert_received {:smtp, "EHLO probe.example"}
      refute_received {:smtp, "STARTTLS"}
      assert_received {:smtp, "QUIT"}
    end

    test "sends IP address EHLO names as address literals" do
      port = start_server([])

      assert {:up, _} =
               SMTP.run(monitor(port, %{smtp_security: "none", smtp_ehlo_name: "192.0.2.1"}))

      assert_received {:smtp, "EHLO [192.0.2.1]"}
    end

    test "uses the default EHLO name" do
      port = start_server([])
      monitor = monitor(port, %{smtp_security: "none"})
      monitor = %{monitor | settings: %{monitor.settings | smtp_ehlo_name: nil}}

      assert {:up, _} = SMTP.run(monitor)
      name = SMTP.default_ehlo_name()
      assert_received {:smtp, "EHLO " <> ^name}
    end

    test "is down when the connection is refused" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      assert {:down, %{message: "Connect: connection refused"}} =
               SMTP.run(monitor(port, %{smtp_security: "none"}))
    end

    test "is down on an unexpected greeting" do
      port = start_server(greeting: "554 5.3.2 Not accepting connections")

      assert {:down, %{message: "Greeting: 554 5.3.2 Not accepting connections"}} =
               SMTP.run(monitor(port, %{smtp_security: "none"}))
    end

    test "is down when the greeting doesn't come in time" do
      port = start_server(greeting: :silent)

      assert {:down, %{message: "Greeting: timed out"}} =
               SMTP.run(monitor(port, %{smtp_security: "none"}, timeout_ms: 300))
    end

    test "is down on a reply that isn't SMTP" do
      port = start_server(greeting: "SSH-2.0-OpenSSH_9.6")

      assert {:down, %{message: ~s(Greeting: invalid reply "SSH-2.0-OpenSSH_9.6")}} =
               SMTP.run(monitor(port, %{smtp_security: "none"}))
    end

    test "is down when EHLO is rejected" do
      port = start_server(ehlo_reply: "550 5.7.1 Go away")

      assert {:down, %{message: "EHLO: 550 5.7.1 Go away"}} =
               SMTP.run(monitor(port, %{smtp_security: "none"}))
    end
  end

  describe "STARTTLS" do
    test "upgrades the connection, says EHLO again and evaluates the certificate" do
      port = start_server(tls: tls_config(200))

      assert {:up, details} = SMTP.run(monitor(port, %{}))
      assert details.message =~ ~r/^mx\.test ESMTP Fake – Certificate valid for 19\d days/
      assert details.meta.days_remaining in 199..200
      refute details[:warning]

      assert_received {:smtp, "EHLO probe.example"}
      assert_received {:smtp, "STARTTLS"}
      assert_received {:smtp, "EHLO probe.example"}
      assert_received {:smtp, "QUIT"}
    end

    test "is down when STARTTLS is not advertised" do
      port = start_server(extensions: ["SIZE 10240000"])

      assert {:down, %{message: "STARTTLS: not advertised by the server"}} =
               SMTP.run(monitor(port, %{}))

      refute_received {:smtp, "STARTTLS"}
    end

    test "is down when STARTTLS is refused" do
      port = start_server(starttls_reply: "454 4.7.0 TLS not available")

      assert {:down, %{message: "STARTTLS: 454 4.7.0 TLS not available"}} =
               SMTP.run(monitor(port, %{}))
    end

    test "is down when the certificate can't be verified" do
      port = start_server(tls: tls_config(200))

      assert {:down, %{message: "TLS handshake: " <> reason}} =
               SMTP.run(monitor(port, %{verify_tls: true}))

      assert reason =~ ~r/unknown ca/i
    end

    test "warns when the certificate expires within cert_warn_days" do
      port = start_server(tls: tls_config(20))

      assert {:up, %{warning: true, message: message, meta: %{days_remaining: days}}} =
               SMTP.run(monitor(port, %{}))

      assert message =~ "mx.test ESMTP Fake – Warning: certificate expires in"
      assert days in 19..20
    end

    test "is down when the certificate expires within cert_critical_days" do
      port = start_server(tls: tls_config(3))

      assert {:down, %{message: "Certificate expires in " <> _, meta: %{days_remaining: _}}} =
               SMTP.run(monitor(port, %{}))
    end
  end

  describe "implicit TLS" do
    test "handshakes before the greeting" do
      port = start_server(tls: tls_config(200), implicit_tls: true, tls_extensions: [])

      assert {:up, %{message: message, meta: %{days_remaining: _}}} =
               SMTP.run(monitor(port, %{smtp_security: "tls"}))

      assert message =~ "mx.test ESMTP Fake – Certificate valid"
      refute_received {:smtp, "STARTTLS"}
    end

    test "is down when the server doesn't speak TLS" do
      port = start_server([])

      assert {:down, %{message: "TLS handshake: " <> _}} =
               SMTP.run(monitor(port, %{smtp_security: "tls"}))
    end
  end

  describe "AUTH" do
    @credentials {"monitor@example.com", "s3cret"}

    test "is up with valid credentials (PLAIN)" do
      port = start_server(tls: tls_config(200), credentials: @credentials)

      assert {:up, _} =
               SMTP.run(
                 monitor(port, %{username: "monitor@example.com"},
                   secrets: %{"password" => "s3cret"}
                 )
               )

      assert_received {:smtp, "AUTH PLAIN " <> _}
    end

    test "uses LOGIN when PLAIN isn't offered" do
      port =
        start_server(
          tls: tls_config(200),
          credentials: @credentials,
          tls_extensions: ["AUTH LOGIN"]
        )

      assert {:up, _} =
               SMTP.run(
                 monitor(port, %{username: "monitor@example.com"},
                   secrets: %{"password" => "s3cret"}
                 )
               )

      assert_received {:smtp, "AUTH LOGIN"}
    end

    test "is down with invalid credentials, keeping the certificate meta" do
      port = start_server(tls: tls_config(200), credentials: @credentials)

      assert {:down, %{message: message, meta: %{days_remaining: _}}} =
               SMTP.run(
                 monitor(port, %{username: "monitor@example.com"},
                   secrets: %{"password" => "wrong"}
                 )
               )

      assert message == "AUTH: 535 5.7.8 Authentication credentials invalid"
    end

    test "is down with invalid credentials over LOGIN" do
      port =
        start_server(
          tls: tls_config(200),
          credentials: @credentials,
          tls_extensions: ["AUTH LOGIN"]
        )

      assert {:down, %{message: "AUTH: 535 5.7.8 Authentication credentials invalid"}} =
               SMTP.run(
                 monitor(port, %{username: "monitor@example.com"},
                   secrets: %{"password" => "wrong"}
                 )
               )
    end

    test "is down when AUTH isn't offered" do
      port = start_server(tls: tls_config(200), tls_extensions: [])

      assert {:down, %{message: "AUTH: not offered by the server"}} =
               SMTP.run(monitor(port, %{username: "monitor@example.com"}))
    end

    test "is down when no supported mechanism is offered" do
      port = start_server(tls: tls_config(200), tls_extensions: ["AUTH CRAM-MD5 XOAUTH2"])

      assert {:down, %{message: "AUTH: neither PLAIN nor LOGIN offered (CRAM-MD5 XOAUTH2)"}} =
               SMTP.run(monitor(port, %{username: "monitor@example.com"}))
    end

    test "is not attempted without a username" do
      port = start_server(tls: tls_config(200), tls_extensions: [])

      assert {:up, _} = SMTP.run(monitor(port, %{}))
    end
  end
end
