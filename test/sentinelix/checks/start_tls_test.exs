defmodule Sentinelix.Checks.StartTLSTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Checks.{MailSession, StartTLS}
  alias Sentinelix.FakeStartTLSServer
  alias Sentinelix.Monitoring.Settings

  doctest StartTLS

  defp settings(port), do: %Settings{host: "localhost", port: port, smtp_ehlo_name: "probe.test"}

  # Negotiates STARTTLS and upgrades (unverified), returning the session.
  defp negotiate(port, protocol) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    with {:ok, conn} <- MailSession.open(settings(port), deadline) do
      MailSession.run_steps(
        [&StartTLS.negotiate(&1, protocol), &MailSession.upgrade(&1, verify: false)],
        conn
      )
    end
  end

  setup_all do
    %{tls: FakeStartTLSServer.tls_config(100)}
  end

  describe "smtp" do
    test "greeting, EHLO, STARTTLS, then the handshake", %{tls: tls} do
      port =
        FakeStartTLSServer.start(
          [
            {:send, "220-mail.test ESMTP"},
            {:send, "220 ready"},
            {:expect, "EHLO probe.test"},
            {:send, "250-mail.test"},
            {:send, "250 STARTTLS"},
            {:expect, "STARTTLS"},
            {:send, "220 2.0.0 Ready to start TLS"},
            :tls
          ],
          tls
        )

      assert {:ok, %{mod: :ssl, cert: cert}} = negotiate(port, :smtp)
      assert is_binary(cert)
      assert_received {:fake_server, "EHLO probe.test"}
      assert_received {:fake_server, "STARTTLS"}
    end

    test "a refused STARTTLS names the step and the reply" do
      port =
        FakeStartTLSServer.start([
          {:send, "220 ready"},
          {:expect, ~r/^EHLO /},
          {:send, "250 mail.test"},
          {:expect, "STARTTLS"},
          {:send, "454 4.7.0 TLS not available"}
        ])

      assert {:error, _conn, "STARTTLS: 454 4.7.0 TLS not available"} = negotiate(port, :smtp)
    end

    test "a rejecting greeting is an error" do
      port = FakeStartTLSServer.start([{:send, "554 go away"}])
      assert {:error, _conn, "Greeting: 554 go away"} = negotiate(port, :smtp)
    end

    test "a rejected EHLO is an error" do
      port =
        FakeStartTLSServer.start([
          {:send, "220 ready"},
          {:expect, ~r/^EHLO /},
          {:send, "501 bad name"}
        ])

      assert {:error, _conn, "EHLO: 501 bad name"} = negotiate(port, :smtp)
    end
  end

  describe "imap" do
    test "greeting, STARTTLS, then the handshake", %{tls: tls} do
      port =
        FakeStartTLSServer.start(
          [
            {:send, "* OK [CAPABILITY IMAP4rev1 STARTTLS] ready"},
            {:expect, "A1 STARTTLS"},
            {:send, "A1 OK Begin TLS negotiation now"},
            :tls
          ],
          tls
        )

      assert {:ok, %{mod: :ssl, cert: cert}} = negotiate(port, :imap)
      assert is_binary(cert)
    end

    test "a refused STARTTLS names the step and the response" do
      port =
        FakeStartTLSServer.start([
          {:send, "* OK ready"},
          {:expect, "A1 STARTTLS"},
          {:send, "A1 BAD STARTTLS not supported"}
        ])

      assert {:error, _conn, "STARTTLS: BAD STARTTLS not supported"} = negotiate(port, :imap)
    end

    test "a BYE or PREAUTH greeting is an error" do
      port = FakeStartTLSServer.start([{:send, "* BYE too many connections"}, :close])
      assert {:error, _conn, "Greeting: BYE too many connections"} = negotiate(port, :imap)

      port = FakeStartTLSServer.start([{:send, "* PREAUTH welcome"}])
      assert {:error, _conn, "Greeting: PREAUTH welcome"} = negotiate(port, :imap)
    end
  end

  describe "pop3" do
    test "greeting, STLS, then the handshake", %{tls: tls} do
      port =
        FakeStartTLSServer.start(
          [
            {:send, "+OK POP3 ready"},
            {:expect, "STLS"},
            {:send, "+OK Begin TLS negotiation"},
            :tls
          ],
          tls
        )

      assert {:ok, %{mod: :ssl, cert: cert}} = negotiate(port, :pop3)
      assert is_binary(cert)
    end

    test "a refused STLS names the step and the reply" do
      port =
        FakeStartTLSServer.start([
          {:send, "+OK POP3 ready"},
          {:expect, "STLS"},
          {:send, "-ERR command not supported"}
        ])

      assert {:error, _conn, "STLS: -ERR command not supported"} = negotiate(port, :pop3)
    end

    test "an invalid greeting is an error" do
      port = FakeStartTLSServer.start([{:send, "220 this is SMTP"}])

      assert {:error, _conn, ~s(Greeting: invalid reply "220 this is SMTP")} =
               negotiate(port, :pop3)
    end
  end

  test "a server closing the connection is an error" do
    port = FakeStartTLSServer.start([:close])
    assert {:error, _conn, "Greeting: connection closed"} = negotiate(port, :pop3)
  end

  test "a failed handshake is an error" do
    port =
      FakeStartTLSServer.start([
        {:send, "+OK POP3 ready"},
        {:expect, "STLS"},
        {:send, "+OK Begin TLS negotiation"},
        :close
      ])

    assert {:error, _conn, "TLS handshake: " <> _} = negotiate(port, :pop3)
  end
end
