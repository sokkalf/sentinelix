defmodule Sentinelix.Monitoring.AutoLabelsTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Monitoring.{AutoLabels, Settings}

  doctest AutoLabels

  describe "derive/2" do
    test "the URL host of http monitors" do
      assert AutoLabels.derive(:http, %Settings{url: "https://user:pw@WWW.Example.com./x?y"}) ==
               %{"type" => "http", "host" => "www.example.com"}

      assert AutoLabels.derive(:http, %Settings{url: "http://[2001:DB8::1]:8080/"}) ==
               %{"type" => "http", "host" => "2001:db8::1"}
    end

    test "the host of tcp, ping, dns, cert and postgres monitors" do
      for type <- [:tcp, :ping, :dns, :cert, :postgres] do
        assert AutoLabels.derive(type, %Settings{host: "DB1.example.com.", port: 5432}) ==
                 %{"type" => Atom.to_string(type), "host" => "db1.example.com"}
      end

      assert AutoLabels.derive(:ping, %Settings{host: "192.0.2.1"})["host"] == "192.0.2.1"
      assert AutoLabels.derive(:tcp, %Settings{host: "2001:DB8::1"})["host"] == "2001:db8::1"
    end

    test "only the type for push monitors and monitors without a valid host" do
      assert AutoLabels.derive(:push, %Settings{push_token: "abc"}) == %{"type" => "push"}
      assert AutoLabels.derive(:http, %Settings{url: nil}) == %{"type" => "http"}
      assert AutoLabels.derive(:http, %Settings{url: "not a url"}) == %{"type" => "http"}
      assert AutoLabels.derive(:tcp, %Settings{host: " "}) == %{"type" => "tcp"}
      assert AutoLabels.derive(:tcp, %Settings{host: "fe80::1%eth0"}) == %{"type" => "tcp"}
      assert AutoLabels.derive(:tcp, nil) == %{"type" => "tcp"}
      assert AutoLabels.derive(nil, %Settings{host: "example.com"}) == %{}
    end
  end

  describe "normalize_host/1" do
    test "lowercases and strips ports, brackets and the trailing dot" do
      assert AutoLabels.normalize_host(" Example.COM. ") == "example.com"
      assert AutoLabels.normalize_host("example.com:443") == "example.com"
      assert AutoLabels.normalize_host("[::1]") == "::1"
      assert AutoLabels.normalize_host("::1") == "::1"
      assert AutoLabels.normalize_host("") == nil
      assert AutoLabels.normalize_host(".") == nil
      assert AutoLabels.normalize_host(nil) == nil
    end
  end

  test "reserved?/1" do
    assert AutoLabels.reserved?("type")
    assert AutoLabels.reserved?("host")
    refute AutoLabels.reserved?("env")
    assert AutoLabels.keys() == ["host", "type"]
  end
end
