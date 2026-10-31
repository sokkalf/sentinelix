defmodule SentinelixWeb.Plugs.ClientIPTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias SentinelixWeb.Plugs.ClientIP

  defp proxies(entries) do
    {:ok, cidrs} = ClientIP.parse_proxies(entries)
    cidrs
  end

  defp call(peer, forwarded, trusted) do
    conn = conn(:get, "/") |> Map.put(:remote_ip, peer)

    conn =
      Enum.reduce(List.wrap(forwarded), conn, fn value, conn ->
        %{conn | req_headers: conn.req_headers ++ [{"x-forwarded-for", value}]}
      end)

    ClientIP.call(conn, ClientIP.init(trusted_proxies: proxies(trusted))).remote_ip
  end

  describe "parse_proxies/1" do
    test "parses addresses and CIDR ranges" do
      assert ClientIP.parse_proxies(["127.0.0.1", " 10.0.0.0/8", "::1", "fd00::/8"]) ==
               {:ok,
                [
                  {{127, 0, 0, 1}, 32},
                  {{10, 0, 0, 0}, 8},
                  {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
                  {{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8}
                ]}
    end

    test "rejects invalid entries" do
      assert ClientIP.parse_proxies(["10.0.0.0/33"]) == {:error, "10.0.0.0/33"}
      assert ClientIP.parse_proxies(["10.0.0.0/x"]) == {:error, "10.0.0.0/x"}
      assert ClientIP.parse_proxies(["proxy.local"]) == {:error, "proxy.local"}
      assert ClientIP.parse_proxies(["10.0.0"]) == {:error, "10.0.0"}
    end
  end

  describe "call/2" do
    test "ignores X-Forwarded-For without trusted proxies" do
      assert call({192, 0, 2, 1}, "198.51.100.7", []) == {192, 0, 2, 1}
    end

    test "ignores X-Forwarded-For from an untrusted peer" do
      assert call({192, 0, 2, 1}, "198.51.100.7", ["10.0.0.0/8"]) == {192, 0, 2, 1}
    end

    test "uses the forwarded address from a trusted peer" do
      assert call({10, 1, 2, 3}, "198.51.100.7", ["10.0.0.0/8"]) == {198, 51, 100, 7}
    end

    test "takes the rightmost untrusted address, so clients can't spoof it" do
      # The client sent a fake header; the proxy appended the real address.
      assert call({10, 1, 2, 3}, "203.0.113.9, 198.51.100.7", ["10.0.0.0/8"]) ==
               {198, 51, 100, 7}

      # Two trusted proxies in a row.
      assert call({10, 1, 2, 3}, ["203.0.113.9, 198.51.100.7", "10.9.9.9"], ["10.0.0.0/8"]) ==
               {198, 51, 100, 7}
    end

    test "stops at an unparsable entry" do
      assert call({10, 1, 2, 3}, "198.51.100.7, garbage, 10.9.9.9", ["10.0.0.0/8"]) ==
               {10, 9, 9, 9}
    end

    test "keeps the peer when there is no header" do
      assert call({10, 1, 2, 3}, [], ["10.0.0.0/8"]) == {10, 1, 2, 3}
    end

    test "handles IPv6 and IPv4-mapped peers" do
      assert call({0, 0, 0, 0, 0, 0, 0, 1}, "2001:db8::1", ["::1"]) ==
               {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

      assert call({0, 0, 0, 0, 0, 0xFFFF, 0x0A01, 0x0203}, "198.51.100.7", ["10.0.0.0/8"]) ==
               {198, 51, 100, 7}
    end
  end

  describe "from_connect_info/3" do
    test "reads LiveView's peer data and x-headers like the plug reads a request" do
      opts = [trusted_proxies: proxies(["10.0.0.0/8"])]
      headers = [{"x-request-id", "abc"}, {"x-forwarded-for", "203.0.113.9, 198.51.100.7"}]

      assert ClientIP.from_connect_info(%{address: {10, 1, 2, 3}}, headers, opts) ==
               {198, 51, 100, 7}

      assert ClientIP.from_connect_info(%{address: {192, 0, 2, 1}}, headers, opts) ==
               {192, 0, 2, 1}

      assert ClientIP.from_connect_info(%{address: {10, 1, 2, 3}}, nil, opts) == {10, 1, 2, 3}
      assert ClientIP.from_connect_info(nil, headers, opts) == nil
    end
  end
end
