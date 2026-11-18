defmodule Sentinelix.FakeStartTLSServer do
  @moduledoc """
  A scripted line based server for STARTTLS tests. Each connection runs the
  script, a list of:

    * `{:send, line}` – send `line` with CRLF
    * `{:expect, line_or_regex}` – receive a line and report it to the test
      process as `{:fake_server, line}`; a line that doesn't match ends the
      session
    * `:tls` – TLS handshake with the server config given to `start/2`
    * `:close` – close the connection

  and then waits until the client closes the connection.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  # The default test keys are not acceptable for TLS 1.3.
  @key [digest: :sha256, key: {:namedCurve, :secp256r1}]

  @doc "A TLS server config whose certificate is valid for `days` more."
  def tls_config(days) do
    %{server_config: config} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: @key ++ [validity: {date(-400), date(400)}],
          peer: @key ++ [validity: {date(-10), date(days)}]
        },
        client_chain: %{root: [], peer: []}
      })

    config
  end

  defp date(days), do: Date.utc_today() |> Date.add(days) |> Date.to_erl()

  @doc "Starts the server (stopped with the test) and returns its port."
  def start(script, tls_config \\ []) do
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
    server = spawn_link(fn -> accept_loop(listen, script, tls_config, test_pid) end)
    on_exit(fn -> Process.exit(server, :kill) end)
    port
  end

  defp accept_loop(listen, script, tls_config, test_pid) do
    {:ok, socket} = :gen_tcp.accept(listen)
    run(script, {:gen_tcp, socket}, tls_config, test_pid)
    accept_loop(listen, script, tls_config, test_pid)
  end

  defp run([], {mod, socket}, _tls_config, _test_pid) do
    # Until the client is done.
    _ = mod.recv(socket, 0, 5_000)
    mod.close(socket)
  end

  defp run([{:send, line} | script], {mod, socket} = conn, tls_config, test_pid) do
    :ok = mod.send(socket, [line, "\r\n"])
    run(script, conn, tls_config, test_pid)
  end

  defp run([{:expect, expected} | script], {mod, socket} = conn, tls_config, test_pid) do
    with {:ok, line} <- mod.recv(socket, 0, 5_000),
         line = String.trim_trailing(line),
         send(test_pid, {:fake_server, line}),
         true <- matches?(line, expected) do
      run(script, conn, tls_config, test_pid)
    else
      _ -> mod.close(socket)
    end
  end

  defp run([:tls | script], {:gen_tcp, socket}, tls_config, test_pid) do
    options = [active: false, packet: :line, mode: :binary, log_level: :none] ++ tls_config

    case :ssl.handshake(socket, options, 5_000) do
      {:ok, ssl} -> run(script, {:ssl, ssl}, tls_config, test_pid)
      {:error, _} -> :gen_tcp.close(socket)
    end
  end

  defp run([:close | _script], {mod, socket}, _tls_config, _test_pid), do: mod.close(socket)

  defp matches?(line, %Regex{} = regex), do: Regex.match?(regex, line)
  defp matches?(line, expected), do: line == expected
end
