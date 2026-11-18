defmodule Sentinelix.Checks.StartTLS do
  @moduledoc """
  STARTTLS negotiation for protocols that start in plain text and upgrade
  the connection to TLS, on a `Sentinelix.Checks.MailSession` connection.

  `negotiate/2` runs the protocol up to the point where the server expects
  the TLS handshake:

  | Protocol | Greeting | Command      | Expected reply |
  | -------- | -------- | ------------ | -------------- |
  | `:smtp`  | `220`    | `EHLO`, then `STARTTLS` | `250`, then `220` |
  | `:imap`  | `* OK`   | `A1 STARTTLS` | `A1 OK`       |
  | `:pop3`  | `+OK`    | `STLS`       | `+OK`          |

  The caller then upgrades the socket with `MailSession.upgrade/2`. Errors
  name the failing step and the server's reply, e.g. `STARTTLS: 454 TLS
  not available`.

  The replies are read with the protocol code of `Sentinelix.Checks.SMTP`
  and `Sentinelix.Checks.IMAP`. Those checks run STARTTLS as part of
  their full sessions (with capability checks); this module is for checks
  that only need the TLS connection, like certificate monitors.
  """

  alias Sentinelix.Checks.{IMAP, MailSession, SMTP}

  @type protocol :: :smtp | :imap | :pop3

  @protocols %{"smtp" => :smtp, "imap" => :imap, "pop3" => :pop3}

  @doc """
  The protocol for a `cert_starttls` setting, `nil` for `"none"` (or no
  setting).

      iex> Sentinelix.Checks.StartTLS.protocol("imap")
      :imap
      iex> Sentinelix.Checks.StartTLS.protocol("none")
      nil
  """
  @spec protocol(String.t() | nil) :: protocol() | nil
  def protocol(name), do: Map.get(@protocols, name)

  @doc """
  Negotiates STARTTLS for `protocol` on a plain connection. On success the
  server is waiting for the TLS handshake.
  """
  @spec negotiate(MailSession.conn(), protocol()) :: MailSession.step_result()
  def negotiate(conn, :smtp) do
    with {:ok, conn} <- smtp_greeting(conn),
         {:ok, _lines} <- SMTP.command(conn, "EHLO #{SMTP.ehlo_name(conn.settings)}", "EHLO", 250),
         {:ok, _lines} <- SMTP.command(conn, "STARTTLS", "STARTTLS", 220) do
      {:ok, conn}
    end
  end

  def negotiate(conn, :imap) do
    with {:ok, conn} <- imap_greeting(conn),
         {:ok, conn, _untagged} <-
           IMAP.command(Map.put_new(conn, :tag, 0), "STARTTLS", ["STARTTLS"]) do
      {:ok, conn}
    end
  end

  def negotiate(conn, :pop3) do
    with {:ok, conn} <- pop3_reply(conn, "Greeting"),
         :ok <- send_line(conn, "STLS", "STLS") do
      pop3_reply(conn, "STLS")
    end
  end

  defp smtp_greeting(conn) do
    case SMTP.read_reply(conn) do
      {:ok, 220, _lines} -> {:ok, conn}
      {:ok, _code, lines} -> {:error, conn, "Greeting: #{List.last(lines)}"}
      {:error, reason} -> {:error, conn, "Greeting: #{format_error(reason)}"}
    end
  end

  defp imap_greeting(conn) do
    case MailSession.recv_line(conn) do
      {:ok, "* OK" <> _} -> {:ok, conn}
      {:ok, "* " <> response} -> {:error, conn, "Greeting: #{response}"}
      {:ok, line} -> {:error, conn, "Greeting: #{format_error({:bad_reply, line})}"}
      {:error, reason} -> {:error, conn, "Greeting: #{format_error(reason)}"}
    end
  end

  # A POP3 status line: +OK or -ERR (RFC 1939, 3).
  defp pop3_reply(conn, step) do
    case MailSession.recv_line(conn) do
      {:ok, "+OK" <> _} -> {:ok, conn}
      {:ok, "-ERR" <> _ = line} -> {:error, conn, "#{step}: #{line}"}
      {:ok, line} -> {:error, conn, "#{step}: #{format_error({:bad_reply, line})}"}
      {:error, reason} -> {:error, conn, "#{step}: #{format_error(reason)}"}
    end
  end

  defp send_line(conn, line, step) do
    case MailSession.send_line(conn, line) do
      :ok -> :ok
      {:error, reason} -> {:error, conn, "#{step}: #{format_error(reason)}"}
    end
  end

  defp format_error(reason), do: MailSession.format_error(reason)
end
