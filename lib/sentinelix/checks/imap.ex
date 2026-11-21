defmodule Sentinelix.Checks.IMAP do
  @moduledoc """
  IMAP check: speaks IMAP to a mail server instead of only checking that
  its port is open. Read-only: the mailbox is opened with `EXAMINE`, so no
  flags change.

  ## Check flow

    1. Connect over TLS (`imap_security: "tls"`, the default) or TCP,
       expect an `* OK` greeting (`* PREAUTH` is accepted too; `* BYE` is
       `:down`).
    2. With `imap_security: "starttls"`: `CAPABILITY` must list `STARTTLS`
       – a stripped or misconfigured STARTTLS is `:down` – then `STARTTLS`
       and the connection is upgraded.
    3. With a `username`: `LOGIN` with the monitor's `password` secret
       (`AUTHENTICATE PLAIN` when the server advertises `LOGINDISABLED`),
       expect `OK`; then `EXAMINE` the `imap_mailbox` (default `INBOX`),
       expect `OK`.
    4. `LOGOUT`.

  The result is `:up` with the greeting text and, after `EXAMINE`, the
  mailbox's message count (also in `meta: %{messages: n}`), or `:down` with
  the failing step and the server's response (e.g. `LOGIN: NO
  [AUTHENTICATIONFAILED] Authentication failed.`).

  ## TLS

  TLS connections are verified (unless `verify_tls` is off) and their
  certificate's expiry is evaluated with the monitor's `cert_warn_days` and
  `cert_critical_days`, see `Sentinelix.Checks.MailSession`.
  """

  @behaviour Sentinelix.Checks.Check

  alias Sentinelix.Checks.MailSession
  alias Sentinelix.Monitoring.{Monitor, Settings}

  # A response with more untagged lines than this is treated as an error.
  @max_response_lines 1_000

  @impl true
  def run(%Monitor{settings: %Settings{} = settings} = monitor) do
    password = Monitor.secret(monitor, "password")
    MailSession.run(monitor, &probe(settings, password, &1))
  end

  ## Session

  defp probe(settings, password, deadline) do
    state = %{
      password: password,
      tag: 0,
      banner: nil,
      capabilities: nil,
      authenticated: false,
      messages: nil
    }

    with {:ok, conn} <- MailSession.open(settings, deadline, state),
         {:ok, conn} <- MailSession.run_steps(steps(settings), conn) do
      {:ok, conn, details(conn)}
    end
  end

  defp details(%{messages: nil} = conn), do: %{message: conn.banner}

  defp details(%{messages: count} = conn) do
    %{
      message: "#{conn.banner} – #{conn.settings.imap_mailbox}: #{pluralize_messages(count)}",
      meta: %{messages: count}
    }
  end

  defp pluralize_messages(1), do: "1 message"
  defp pluralize_messages(n), do: "#{n} messages"

  defp steps(%Settings{imap_security: security, username: username}) do
    [
      if(security == "tls", do: &MailSession.upgrade/1),
      &greeting/1,
      if(security == "starttls", do: &starttls/1),
      if(is_binary(username), do: &login/1),
      &examine/1,
      &logout/1
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp greeting(conn) do
    case MailSession.recv_line(conn) do
      {:ok, "* OK" <> text} ->
        {:ok, greeted(conn, text)}

      {:ok, "* PREAUTH" <> text} ->
        {:ok, %{greeted(conn, text) | authenticated: true}}

      {:ok, "* BYE" <> text} ->
        {:error, conn, "Greeting: BYE#{text}"}

      {:ok, line} ->
        {:error, conn, "Greeting: #{format_error({:bad_reply, line})}"}

      {:error, reason} ->
        {:error, conn, "Greeting: #{format_error(reason)}"}
    end
  end

  defp greeted(conn, text) do
    banner = with "" <- response_text(text), do: "Connected"
    %{conn | banner: banner, capabilities: response_capabilities(text)}
  end

  defp starttls(%{authenticated: true} = conn),
    do: {:error, conn, "STARTTLS: not possible, the server pre-authenticated the session"}

  defp starttls(conn) do
    case fetch_capabilities(conn) do
      {:ok, %{capabilities: capabilities} = conn} ->
        if "STARTTLS" in capabilities,
          do: upgrade(conn),
          else: {:error, conn, "STARTTLS: not advertised by the server"}

      error ->
        error
    end
  end

  defp upgrade(conn) do
    with {:ok, conn, _untagged} <- command(conn, "STARTTLS", ["STARTTLS"]),
         {:ok, conn} <- MailSession.upgrade(conn) do
      # Capabilities from before STARTTLS must be discarded (RFC 3501, 6.2.1).
      {:ok, %{conn | capabilities: nil}}
    end
  end

  # Already authenticated by PREAUTH.
  defp login(%{authenticated: true} = conn), do: {:ok, conn}

  defp login(conn) do
    with {:ok, conn} <- fetch_capabilities(conn) do
      username = conn.settings.username
      password = conn.password || ""

      cond do
        "LOGINDISABLED" not in conn.capabilities ->
          authenticated(
            command(conn, "LOGIN", ["LOGIN ", astring(username), " ", astring(password)])
          )

        "AUTH=PLAIN" in conn.capabilities ->
          token = Base.encode64(<<0, username::binary, 0, password::binary>>)
          authenticated(command(conn, "AUTHENTICATE", ["AUTHENTICATE PLAIN", {:continue, token}]))

        true ->
          {:error, conn,
           "LOGIN: disabled by the server (LOGINDISABLED) and AUTHENTICATE PLAIN not offered"}
      end
    end
  end

  defp authenticated({:ok, conn, _untagged}), do: {:ok, %{conn | authenticated: true}}
  defp authenticated(error), do: error

  defp examine(%{authenticated: false} = conn), do: {:ok, conn}

  defp examine(conn) do
    mailbox = conn.settings.imap_mailbox

    with {:ok, conn, untagged} <-
           command(conn, "EXAMINE #{mailbox}", [
             "EXAMINE ",
             mailbox |> encode_mailbox() |> astring()
           ]) do
      {:ok, %{conn | messages: exists(untagged)}}
    end
  end

  # The server's response to LOGOUT doesn't matter: everything has been checked.
  defp logout(conn) do
    case command(conn, "LOGOUT", ["LOGOUT"]) do
      {:ok, conn, _untagged} -> {:ok, conn}
      {:error, conn, _message} -> {:ok, conn}
    end
  end

  defp fetch_capabilities(%{capabilities: capabilities} = conn) when is_list(capabilities),
    do: {:ok, conn}

  defp fetch_capabilities(conn) do
    with {:ok, conn, untagged} <- command(conn, "CAPABILITY", ["CAPABILITY"]) do
      capabilities =
        Enum.flat_map(untagged, fn
          "* CAPABILITY " <> list -> capability_list(list)
          _ -> []
        end)

      {:ok, %{conn | capabilities: capabilities}}
    end
  end

  ## Protocol

  @doc """
  Sends a tagged command and reads the response up to the tagged status,
  which must be OK. The session keeps the last tag number in `:tag`.

  `parts` are strings, `{:literal, binary}` (sent as a synchronizing
  literal) and `{:continue, line}` (a line sent after the server's
  continuation request, e.g. an AUTHENTICATE response). Returns the
  untagged response lines, or an error naming `step` and the server's
  response.
  """
  @spec command(MailSession.conn(), String.t(), [
          iodata() | {:literal, binary()} | {:continue, iodata()}
        ]) ::
          {:ok, MailSession.conn(), [String.t()]} | {:error, MailSession.conn(), String.t()}
  def command(conn, step, parts) do
    tag = "A#{conn.tag + 1}"
    conn = %{conn | tag: conn.tag + 1}
    [first | rest] = chunks(parts)

    with :ok <- MailSession.send_line(conn, [tag, " ", first]),
         :ok <- send_continued(conn, tag, rest),
         {:ok, untagged} <- read_response(conn, tag) do
      {:ok, conn, untagged}
    else
      {:error, reason} -> {:error, conn, "#{step}: #{format_error(reason)}"}
    end
  end

  # Splits the command into the lines sent before and after each
  # continuation request.
  defp chunks(parts) do
    {chunks, current} =
      Enum.reduce(parts, {[], []}, fn
        {:literal, value}, {chunks, current} ->
          {[[current, "{#{byte_size(value)}}"] | chunks], [value]}

        {:continue, line}, {chunks, current} ->
          {[current | chunks], [line]}

        part, {chunks, current} ->
          {chunks, [current, part]}
      end)

    Enum.reverse([current | chunks])
  end

  defp send_continued(_conn, _tag, []), do: :ok

  defp send_continued(conn, tag, [chunk | rest]) do
    with :ok <- await_continuation(conn, tag),
         :ok <- MailSession.send_line(conn, chunk) do
      send_continued(conn, tag, rest)
    end
  end

  defp await_continuation(conn, tag) do
    with {:ok, line} <- MailSession.recv_line(conn) do
      case response_line(line, tag) do
        :continuation -> :ok
        :untagged -> await_continuation(conn, tag)
        {:tagged, _ok?, response} -> {:error, {:response, response}}
        :invalid -> {:error, {:bad_reply, line}}
      end
    end
  end

  defp read_response(conn, tag, untagged \\ []) do
    case MailSession.recv_line(conn) do
      {:ok, line} -> handle_response_line(conn, tag, untagged, line)
      {:error, :closed} -> {:error, closed_reason(untagged)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_response_line(conn, tag, untagged, line) do
    case response_line(line, tag) do
      :untagged when length(untagged) < @max_response_lines ->
        read_response(conn, tag, [line | untagged])

      {:tagged, true, _response} ->
        {:ok, Enum.reverse(untagged)}

      {:tagged, false, response} ->
        {:error, {:response, response}}

      _ ->
        {:error, {:bad_reply, line}}
    end
  end

  # A server closing the connection says why in an untagged BYE.
  defp closed_reason(untagged) do
    case Enum.find(untagged, &String.starts_with?(&1, "* BYE")) do
      "* " <> bye -> {:response, bye}
      nil -> :closed
    end
  end

  defp response_line("* " <> _, _tag), do: :untagged
  defp response_line("+" <> _, _tag), do: :continuation

  defp response_line(line, tag) do
    case String.split(line, " ", parts: 2) do
      [^tag, "OK" <> _ = response] -> {:tagged, true, response}
      [^tag, "NO" <> _ = response] -> {:tagged, false, response}
      [^tag, "BAD" <> _ = response] -> {:tagged, false, response}
      _ -> :invalid
    end
  end

  # The human readable text of a status response, without the response
  # code, e.g. " [CAPABILITY IMAP4rev1] Dovecot ready." => "Dovecot ready."
  defp response_text(text) do
    text |> String.replace(~r/\A\s*\[[^\]]*\]/, "") |> String.trim()
  end

  # The capabilities of a `[CAPABILITY ...]` response code, or nil.
  defp response_capabilities(text) do
    case Regex.run(~r/\A\s*\[CAPABILITY ([^\]]*)\]/i, text) do
      [_, list] -> capability_list(list)
      nil -> nil
    end
  end

  defp capability_list(list), do: list |> String.upcase() |> String.split()

  # The message count of an EXAMINE / SELECT response (`* 42 EXISTS`).
  defp exists(untagged) do
    Enum.find_value(untagged, fn line ->
      case Regex.run(~r/\A\* (\d+) EXISTS\z/i, line) do
        [_, count] -> String.to_integer(count)
        nil -> nil
      end
    end)
  end

  # An IMAP astring argument: a quoted string, or a literal for values a
  # quoted string can't hold (8-bit characters, CR, LF, NUL).
  defp astring(value) do
    if value =~ ~r/\A[\x01-\x09\x0b\x0c\x0e-\x7f]*\z/ do
      [?", String.replace(value, ["\\", "\""], &("\\" <> &1)), ?"]
    else
      {:literal, value}
    end
  end

  @doc """
  Encodes a mailbox name in IMAP's modified UTF-7 (RFC 3501, 5.1.3):
  printable ASCII stays as is (`&` becomes `&-`), other characters are
  modified BASE64 encoded UTF-16 between `&` and `-`.

      iex> Sentinelix.Checks.IMAP.encode_mailbox("Entwürfe & Co")
      "Entw&APw-rfe &- Co"
  """
  @spec encode_mailbox(String.t()) :: String.t()
  def encode_mailbox(name) do
    ~r/[^\x20-\x7e]+/u
    |> Regex.split(name, include_captures: true, trim: true)
    |> Enum.map_join(fn run ->
      if run =~ ~r/\A[\x20-\x7e]+\z/ do
        String.replace(run, "&", "&-")
      else
        utf16 = :unicode.characters_to_binary(run, :utf8, :utf16)
        "&" <> (utf16 |> Base.encode64(padding: false) |> String.replace("/", ",")) <> "-"
      end
    end)
  end

  defp format_error({:response, response}), do: response
  defp format_error(reason), do: MailSession.format_error(reason)
end
