defmodule Sentinelix.Checks.DNSTest do
  # Not async: points the resolver port of the DNS check at a fake server.
  use ExUnit.Case, async: false

  alias Sentinelix.Checks.DNS
  alias Sentinelix.Monitoring.Monitor

  # A minimal UDP name server on localhost answering from a zone map of
  # {name, type} => [data]; names not in the zone get NXDOMAIN, and
  # "slow.example.com" gets no answer at all.
  defmodule FakeServer do
    def start(zone) do
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(socket)
      pid = spawn_link(fn -> loop(socket, zone) end)
      :ok = :gen_udp.controlling_process(socket, pid)
      port
    end

    defp loop(socket, zone) do
      {:ok, {ip, port, packet}} = :gen_udp.recv(socket, 0)
      {:ok, query} = :inet_dns.decode(packet)
      [question] = :inet_dns.msg(query, :qdlist)
      name = question |> :inet_dns.dns_query(:domain) |> to_string()
      type = :inet_dns.dns_query(question, :type)

      if name != "slow.example.com" do
        :ok = :gen_udp.send(socket, ip, port, response(query, zone, name, type))
      end

      loop(socket, zone)
    end

    defp response(query, zone, name, type) do
      {rcode, answers} =
        case Map.fetch(zone, {name, type}) do
          {:ok, data} -> {0, Enum.map(data, &rr(name, type, &1))}
          :error when is_map_key(zone, name) -> {0, []}
          :error -> {3, []}
        end

      header =
        :inet_dns.make_header(:inet_dns.msg(query, :header), qr: true, ra: true, rcode: rcode)

      query
      |> :inet_dns.make_msg(header: header, anlist: answers)
      |> :inet_dns.encode()
    end

    defp rr(name, type, data) do
      :inet_dns.make_rr(
        domain: String.to_charlist(name),
        type: type,
        class: :in,
        ttl: 60,
        data: data
      )
    end
  end

  @zone %{
    "example.com" => true,
    {"example.com", :a} => [{192, 0, 2, 1}, {192, 0, 2, 2}],
    {"example.com", :aaaa} => [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}],
    {"example.com", :mx} => [{10, ~c"mail.example.com"}, {20, ~c"backup.example.com"}],
    {"example.com", :txt} => [[~c"v=spf1 ", ~c"-all"], [~c"other"]],
    {"example.com", :ns} => [~c"ns1.example.com"],
    {"www.example.com", :cname} => [~c"example.com"]
  }

  setup do
    port = FakeServer.start(@zone)
    Application.put_env(:sentinelix, DNS, resolver_port: port)
    on_exit(fn -> Application.delete_env(:sentinelix, DNS) end)
  end

  defp monitor(settings, timeout_ms \\ 2_000) do
    %Monitor{}
    |> Monitor.changeset(%{
      name: "test",
      type: :dns,
      timeout_ms: timeout_ms,
      settings: Map.merge(%{host: "example.com", dns_resolver: "127.0.0.1"}, settings)
    })
    |> Ecto.Changeset.apply_action!(:insert)
  end

  test "resolves A records" do
    assert {:up, details} = DNS.run(monitor(%{}))
    assert details.message == "A: 192.0.2.1, 192.0.2.2"
    assert details.meta == %{records: ["192.0.2.1", "192.0.2.2"]}
    assert is_integer(details.response_time_ms)
  end

  test "resolves the other record types" do
    assert {:up, %{meta: %{records: ["2001:db8::1"]}}} =
             DNS.run(monitor(%{dns_record_type: "AAAA"}))

    assert {:up, %{meta: %{records: ["10 mail.example.com", "20 backup.example.com"]}}} =
             DNS.run(monitor(%{dns_record_type: "MX"}))

    assert {:up, %{meta: %{records: ["v=spf1 -all", "other"]}}} =
             DNS.run(monitor(%{dns_record_type: "TXT"}))

    assert {:up, %{meta: %{records: ["ns1.example.com"]}}} =
             DNS.run(monitor(%{dns_record_type: "NS"}))

    assert {:up, %{message: "CNAME: example.com"}} =
             DNS.run(monitor(%{host: "www.example.com", dns_record_type: "CNAME"}))
  end

  test "matches the expected value" do
    assert {:up, %{message: "A: 192.0.2.1, 192.0.2.2 (matches 192.0.2.2)"}} =
             DNS.run(monitor(%{expected_value: "192.0.2.2"}))

    assert {:down, %{message: "A: 192.0.2.1, 192.0.2.2 (expected 192.0.2.3)"}} =
             DNS.run(monitor(%{expected_value: "192.0.2.3"}))

    assert {:up, _} =
             DNS.run(monitor(%{dns_record_type: "AAAA", expected_value: "2001:DB8:0::1"}))

    assert {:up, _} =
             DNS.run(monitor(%{dns_record_type: "MX", expected_value: "Mail.Example.com."}))

    assert {:up, _} =
             DNS.run(monitor(%{dns_record_type: "MX", expected_value: "20 backup.example.com"}))

    assert {:down, _} =
             DNS.run(monitor(%{dns_record_type: "MX", expected_value: "20 mail.example.com"}))

    assert {:up, _} = DNS.run(monitor(%{dns_record_type: "TXT", expected_value: "v=spf1 -all"}))
    assert {:down, _} = DNS.run(monitor(%{dns_record_type: "TXT", expected_value: "V=SPF1 -all"}))

    assert {:up, _} =
             DNS.run(
               monitor(%{
                 host: "www.example.com",
                 dns_record_type: "CNAME",
                 expected_value: "example.com."
               })
             )
  end

  test "no records of the type is down" do
    assert {:down, %{message: "No CNAME records found", meta: %{records: []}}} =
             DNS.run(monitor(%{dns_record_type: "CNAME"}))
  end

  test "NXDOMAIN is down" do
    assert {:down, %{message: "DNS lookup failed: host not found (NXDOMAIN)"}} =
             DNS.run(monitor(%{host: "missing.example.com"}))
  end

  test "a resolver that doesn't answer is down" do
    assert {:down, %{message: "DNS lookup failed: timed out"}} =
             DNS.run(monitor(%{host: "slow.example.com"}, 300))
  end

  test "evaluate/2 shortens long record lists" do
    settings = monitor(%{}).settings
    records = Enum.map(1..8, &"192.0.2.#{&1}")

    assert {:up, %{message: message}} = DNS.evaluate(records, settings)
    assert message == "A: 192.0.2.1, 192.0.2.2, 192.0.2.3, 192.0.2.4, 192.0.2.5 (+3 more)"
  end
end
