defmodule Sentinelix.Checks.CertTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Checks.Cert
  alias Sentinelix.Monitoring.{Monitor, Settings}

  @settings %Settings{host: "localhost", port: 443, cert_warn_days: 30, cert_critical_days: 7}
  @now ~U[2026-06-15 12:00:00Z]

  # A self-signed DER certificate valid between the given dates
  # ({year, month, day} tuples).
  defp certificate(from, to) do
    %{cert: der} = :public_key.pkix_test_root_cert(~c"Test", validity: {from, to})
    der
  end

  defp date_tuple(%Date{} = date), do: Date.to_erl(date)
  defp days_from_today(days), do: Date.utc_today() |> Date.add(days) |> date_tuple()

  describe "parse_time/1" do
    test "utcTime with years from 1950 to 2049" do
      assert Cert.parse_time({:utcTime, ~c"250101083000Z"}) == {:ok, ~U[2025-01-01 08:30:00Z]}
      assert Cert.parse_time({:utcTime, ~c"491231235959Z"}) == {:ok, ~U[2049-12-31 23:59:59Z]}
      assert Cert.parse_time({:utcTime, ~c"500101000000Z"}) == {:ok, ~U[1950-01-01 00:00:00Z]}
      assert Cert.parse_time({:utcTime, ~c"991231235959Z"}) == {:ok, ~U[1999-12-31 23:59:59Z]}
    end

    test "generalTime for dates from 2050" do
      assert Cert.parse_time({:generalTime, ~c"20600101130000Z"}) ==
               {:ok, ~U[2060-01-01 13:00:00Z]}
    end

    test "invalid times" do
      assert {:error, _} = Cert.parse_time({:utcTime, ~c"garbage"})
      assert {:error, _} = Cert.parse_time({:utcTime, ~c"251301000000Z"})
      assert {:error, _} = Cert.parse_time({:generalTime, ~c"2060010113"})
      assert {:error, _} = Cert.parse_time(:nope)
    end
  end

  describe "validity/1" do
    test "reads utcTime and generalTime validity" do
      der = certificate({2000, 1, 1}, {2060, 1, 1})
      assert {:ok, from, to} = Cert.validity(der)
      assert from.year == 2000
      assert to.year == 2060
    end

    test "rejects garbage" do
      assert {:error, _} = Cert.validity("not a certificate")
    end
  end

  describe "evaluate/4" do
    test "up when far from expiry" do
      assert {:up, details} =
               Cert.evaluate(~U[2026-01-01 00:00:00Z], ~U[2026-12-01 00:00:00Z], @settings, @now)

      assert details.message =~ "Certificate valid for 168 days"
      assert details.meta.days_remaining == 168
      refute details[:warning]
    end

    test "up with a warning within cert_warn_days" do
      assert {:up, %{warning: true, message: message, meta: %{days_remaining: 20}}} =
               Cert.evaluate(~U[2026-01-01 00:00:00Z], ~U[2026-07-05 12:00:00Z], @settings, @now)

      assert message =~ "expires in 20 days"
    end

    test "down within cert_critical_days" do
      assert {:down, %{message: message}} =
               Cert.evaluate(~U[2026-01-01 00:00:00Z], ~U[2026-06-20 12:00:00Z], @settings, @now)

      assert message =~ "expires in 5 days"
    end

    test "down when expired" do
      assert {:down, %{message: message, meta: %{days_remaining: -3}}} =
               Cert.evaluate(~U[2026-01-01 00:00:00Z], ~U[2026-06-12 12:00:00Z], @settings, @now)

      assert message =~ "Certificate expired 3 days ago (2026-06-12 12:00 UTC)"
    end

    test "down when not valid yet" do
      assert {:down, %{message: message}} =
               Cert.evaluate(~U[2026-07-01 00:00:00Z], ~U[2027-07-01 00:00:00Z], @settings, @now)

      assert message =~ "not valid yet"
    end

    test "works on a parsed certificate with generalTime" do
      der = certificate({2020, 1, 1}, {2060, 1, 1})

      assert {:up, %{meta: %{expires_at: ~U[2060-01-01 13:00:00Z]}}} =
               Cert.evaluate_der(der, @settings, @now)
    end
  end

  describe "run/1 against a local TLS server" do
    # The default test keys are not acceptable for TLS 1.3.
    @key [digest: :sha256, key: {:namedCurve, :secp256r1}]

    setup do
      test_pid = self()

      %{server_config: server_config} =
        :public_key.pkix_test_data(%{
          server_chain: %{
            root: @key ++ [validity: {days_from_today(-400), days_from_today(400)}],
            peer: @key ++ [validity: {days_from_today(-10), days_from_today(10)}]
          },
          client_chain: %{root: [], peer: []}
        })

      sni_fun = fn host ->
        send(test_pid, {:sni, host})
        server_config
      end

      {:ok, listen} =
        :ssl.listen(0, [active: false, reuseaddr: true, sni_fun: sni_fun] ++ server_config)

      {:ok, {_, port}} = :ssl.sockname(listen)

      acceptor =
        spawn_link(fn ->
          accept_loop(listen)
        end)

      on_exit(fn -> Process.exit(acceptor, :kill) end)
      %{port: port}
    end

    defp accept_loop(listen) do
      with {:ok, socket} <- :ssl.transport_accept(listen) do
        _ = :ssl.handshake(socket, 5_000)
        accept_loop(listen)
      end
    end

    test "checks the certificate presented for the host, sending SNI", %{port: port} do
      monitor = %Monitor{
        type: :cert,
        timeout_ms: 5_000,
        settings: %{@settings | host: "localhost", port: port}
      }

      assert {:up, %{warning: true, message: message} = details} = Cert.run(monitor)
      assert message =~ "expires in"
      assert details.meta.days_remaining in 9..10
      assert is_integer(details.response_time_ms)
      assert_received {:sni, ~c"localhost"}

      # Critical threshold above the remaining days.
      critical = %{monitor | settings: %{monitor.settings | cert_critical_days: 15}}
      assert {:down, _} = Cert.run(critical)
    end

    test "connection errors are down" do
      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      monitor = %Monitor{type: :cert, timeout_ms: 1_000, settings: %{@settings | port: port}}
      assert {:down, %{message: "TLS connection failed: connection refused"}} = Cert.run(monitor)
    end
  end
end
