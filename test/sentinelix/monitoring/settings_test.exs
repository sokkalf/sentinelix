defmodule Sentinelix.Monitoring.SettingsTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.MonitoringFixtures

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{Monitor, Settings}
  alias Sentinelix.Monitoring.Settings.Assertion

  defp settings_errors(type, settings) do
    changeset =
      Monitoring.change_monitor(%Monitor{}, valid_monitor_attrs(type, %{settings: settings}))

    changeset |> errors_on() |> Map.get(:settings, %{})
  end

  defp valid?(type, settings), do: settings_errors(type, settings) == %{}

  defp apply_settings(type, settings) do
    {:ok, monitor} = Monitoring.create_monitor(valid_monitor_attrs(type, %{settings: settings}))
    monitor.settings
  end

  test "every type has valid example settings and a field list" do
    for type <- Monitor.types() do
      assert valid?(type, valid_settings(type)), "#{type} example settings are invalid"
      assert Settings.fields_for(type) != []
    end
  end

  describe "http" do
    test "requires a valid http(s) URL" do
      assert %{url: ["can't be blank"]} = settings_errors(:http, %{})

      for url <- ["example.com", "ftp://example.com", "https://", "http//x", "  "] do
        refute valid?(:http, %{url: url}), "expected #{inspect(url)} to be rejected"
      end

      for url <- ["http://example.com", "https://example.com:8443/a?b=c", "http://10.0.0.1/"] do
        assert valid?(:http, %{url: url}), "expected #{inspect(url)} to be accepted"
      end

      assert apply_settings(:http, %{url: "  https://example.com  "}).url ==
               "https://example.com"
    end

    test "validates method" do
      assert apply_settings(:http, %{url: "https://example.com", method: "head"}).method ==
               "HEAD"

      assert %{method: ["is invalid"]} =
               settings_errors(:http, %{url: "https://example.com", method: "FETCH"})
    end

    test "validates accepted status codes" do
      base = %{url: "https://example.com"}

      assert valid?(:http, Map.put(base, :accepted_status_codes, ["200", "300-399"]))

      for codes <- [["2xx"], ["600"], ["299-200"], ["200-"]] do
        refute valid?(:http, Map.put(base, :accepted_status_codes, codes)),
               "expected #{inspect(codes)} to be rejected"
      end

      # Blank entries (e.g. an empty form input) are dropped, values trimmed.
      settings = apply_settings(:http, Map.put(base, :accepted_status_codes, ["", " 201 "]))
      assert settings.accepted_status_codes == ["201"]
    end

    test "validates headers" do
      base = %{url: "https://example.com"}

      assert valid?(:http, Map.put(base, :headers, %{"Authorization" => "Bearer x"}))
      refute valid?(:http, Map.put(base, :headers, %{"Bad Header" => "x"}))
      refute valid?(:http, Map.put(base, :headers, %{"X-Inject" => "a\r\nHost: evil"}))
    end

    test "validates max redirects" do
      base = %{url: "https://example.com"}
      assert valid?(:http, Map.put(base, :max_redirects, 0))
      refute valid?(:http, Map.put(base, :max_redirects, -1))
      refute valid?(:http, Map.put(base, :max_redirects, 21))
    end

    test "keeps explicit false booleans" do
      settings =
        apply_settings(:http, %{
          url: "https://example.com",
          follow_redirects: false,
          verify_tls: "false"
        })

      assert settings.follow_redirects == false
      assert settings.verify_tls == false
    end
  end

  describe "http assertions" do
    defp assertion_errors(assertions) do
      case settings_errors(:http, %{url: "https://example.com", assertions: assertions}) do
        %{assertions: errors} -> errors
        _ -> Enum.map(assertions, fn _ -> %{} end)
      end
    end

    test "defaults to none" do
      assert apply_settings(:http, %{url: "https://example.com"}).assertions == []
    end

    test "accepts every source and comparison combination that makes sense" do
      for source <- ~w(body json header),
          comparison <- Assertion.comparisons(source) do
        value =
          cond do
            comparison in ~w(< <= > >=) -> "100"
            comparison in ~w(regex not_regex) -> "^ok$"
            true -> "ok"
          end

        assertion = %{source: source, path: "status", comparison: comparison, value: value}
        assert assertion_errors([assertion]) == [%{}], "#{source} #{comparison}"
      end
    end

    test "normalizes fields that don't apply" do
      settings =
        apply_settings(:http, %{
          url: "https://example.com",
          assertions: [
            %{source: "body", path: "ignored", comparison: "contains", value: " OK "},
            %{source: "header", path: " ETag ", comparison: "exists", value: "ignored"}
          ]
        })

      assert [
               %Assertion{source: "body", path: nil, value: " OK ", case_sensitive: true},
               %Assertion{source: "header", path: "ETag", value: nil}
             ] = settings.assertions
    end

    test "validates source, comparison, path and value" do
      assert [
               %{source: ["is invalid"]},
               %{comparison: ["is invalid"]},
               %{comparison: ["is not available for the body"]},
               %{path: ["can't be blank"]},
               %{path: [~s(must be a dot-separated path like "data.items.0.status")]},
               %{path: ["must be a header name"]},
               %{value: ["can't be blank"]},
               %{value: ["must be a number for <"]},
               %{value: ["must be a valid regular expression"]}
             ] =
               assertion_errors([
                 %{source: "xml", comparison: "contains", value: "x"},
                 %{source: "body", comparison: "like", value: "x"},
                 %{source: "body", comparison: "exists"},
                 %{source: "json", comparison: "exists"},
                 %{source: "json", path: "a..b", comparison: "exists"},
                 %{source: "header", path: "Bad Header", comparison: "exists"},
                 %{source: "body", comparison: "contains", value: ""},
                 %{source: "json", path: "depth", comparison: "<", value: "many"},
                 %{source: "body", comparison: "not_regex", value: "(unclosed"}
               ])
    end

    test "limits the number of assertions" do
      assertion = %{source: "body", comparison: "contains", value: "x"}
      max = Settings.max_assertions()

      assert valid?(:http, %{url: "https://x.com", assertions: List.duplicate(assertion, max)})

      assert %{assertions: [_]} =
               settings_errors(:http, %{
                 url: "https://x.com",
                 assertions: List.duplicate(assertion, max + 1)
               })
    end

    test "are removed when the type changes" do
      {:ok, monitor} =
        Monitoring.create_monitor(
          valid_monitor_attrs(:http, %{
            settings: %{
              url: "https://example.com",
              assertions: [%{source: "body", comparison: "contains", value: "x"}]
            }
          })
        )

      {:ok, monitor} =
        Monitoring.update_monitor(monitor, %{type: :tcp, settings: %{host: "x.com", port: 1}})

      assert monitor.settings.assertions == []
    end
  end

  describe "tcp" do
    test "requires host and port in range" do
      assert %{host: ["can't be blank"], port: ["can't be blank"]} = settings_errors(:tcp, %{})

      assert %{port: [_]} = settings_errors(:tcp, %{host: "example.com", port: 0})
      assert %{port: [_]} = settings_errors(:tcp, %{host: "example.com", port: 65_536})
      assert valid?(:tcp, %{host: "example.com", port: 65_535})
      assert valid?(:tcp, %{host: "::1", port: "22"})
    end
  end

  describe "ping" do
    test "requires a valid hostname or IP" do
      assert %{host: ["can't be blank"]} = settings_errors(:ping, %{})

      for host <- ["example.com", "localhost", "192.0.2.1", "2001:db8::1", "a-b.example.com."] do
        assert valid?(:ping, %{host: host}), "expected #{inspect(host)} to be accepted"
      end

      for host <- ["-c 1000 example.com", "-flood", "exa mple.com", "example..com", "a;rm -rf /"] do
        assert %{host: ["must be a valid hostname or IP address"]} =
                 settings_errors(:ping, %{host: host}),
               "expected #{inspect(host)} to be rejected"
      end
    end
  end

  describe "dns" do
    test "requires host, defaults record type to A and validates resolver" do
      assert %{host: ["can't be blank"]} = settings_errors(:dns, %{})

      settings = apply_settings(:dns, %{host: "_dmarc.example.com", dns_record_type: "txt"})
      assert settings.dns_record_type == "TXT"

      assert apply_settings(:dns, %{host: "example.com"}).dns_record_type == "A"

      assert %{dns_record_type: ["is invalid"]} =
               settings_errors(:dns, %{host: "example.com", dns_record_type: "SRVX"})

      assert valid?(:dns, %{host: "example.com", dns_resolver: "1.1.1.1"})

      assert %{dns_resolver: ["must be a valid IP address"]} =
               settings_errors(:dns, %{host: "example.com", dns_resolver: "dns.google"})
    end
  end

  describe "cert" do
    test "defaults port and expiry thresholds" do
      settings = apply_settings(:cert, %{host: "example.com"})
      assert %Settings{port: 443, cert_warn_days: 30, cert_critical_days: 7} = settings
    end

    test "validates thresholds" do
      assert %{cert_critical_days: ["must not be greater than the warning days"]} =
               settings_errors(:cert, %{
                 host: "example.com",
                 cert_warn_days: 5,
                 cert_critical_days: 10
               })

      assert %{cert_warn_days: [_]} =
               settings_errors(:cert, %{host: "example.com", cert_warn_days: 0})
    end
  end

  describe "push" do
    test "generates a token when none is given and keeps it on update" do
      monitor = monitor_fixture(:push)
      token = monitor.settings.push_token
      assert is_binary(token) and byte_size(token) >= 32

      {:ok, updated} = Monitoring.update_monitor(monitor, %{name: "renamed"})
      assert updated.settings.push_token == token
    end

    test "validates custom tokens" do
      assert valid?(:push, %{push_token: "abcdefghijklmnop"})
      assert %{push_token: [_]} = settings_errors(:push, %{push_token: "short"})
      assert %{push_token: [_]} = settings_errors(:push, %{push_token: "has spaces in the token"})
    end

    test "defaults and validates the grace period" do
      assert apply_settings(:push, %{}).push_grace_seconds == 30
      assert apply_settings(:push, %{push_grace_seconds: 0}).push_grace_seconds == 0
      assert %{push_grace_seconds: [_]} = settings_errors(:push, %{push_grace_seconds: -1})
      assert %{push_grace_seconds: [_]} = settings_errors(:push, %{push_grace_seconds: 86_401})
    end
  end

  describe "postgres" do
    test "requires connection settings and defaults port, SSL mode and query" do
      assert %{host: _, database: _, username: _} = settings_errors(:postgres, %{})

      settings =
        apply_settings(:postgres, %{
          host: " db.example.com ",
          database: " app ",
          username: " monitor ",
          query: "  "
        })

      assert %Settings{
               host: "db.example.com",
               port: 5432,
               database: "app",
               username: "monitor",
               ssl_mode: "require",
               ssl_ca_cert: nil,
               query: "SELECT 1"
             } = settings
    end

    test "validates the SSL mode and CA certificate" do
      valid = valid_settings(:postgres)

      for mode <- Settings.ssl_modes() do
        assert valid?(:postgres, Map.put(valid, :ssl_mode, mode))
      end

      assert %{ssl_mode: ["is invalid"]} =
               settings_errors(:postgres, Map.put(valid, :ssl_mode, "prefer"))

      %{cert: der} = :public_key.pkix_test_root_cert(~c"Test CA", [])
      pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

      assert valid?(:postgres, Map.merge(valid, %{ssl_mode: "verify-full", ssl_ca_cert: pem}))
      assert Settings.parse_ca_certs(pem) == {:ok, [der]}

      assert %{ssl_ca_cert: ["must contain PEM encoded certificates"]} =
               settings_errors(:postgres, Map.put(valid, :ssl_ca_cert, "not a certificate"))
    end

    test "validates the expected result" do
      valid = valid_settings(:postgres)
      settings = apply_settings(:postgres, valid)
      assert %Settings{expected_value: nil, comparison: "equals"} = settings
      assert %Settings{expected_rows: nil, rows_comparison: "equals"} = settings

      assert valid?(:postgres, Map.merge(valid, %{expected_value: "16.", comparison: "contains"}))
      assert valid?(:postgres, Map.merge(valid, %{expected_value: "1.5", comparison: "<="}))

      assert %{comparison: ["is invalid"]} =
               settings_errors(:postgres, Map.put(valid, :comparison, "like"))

      assert %{expected_value: ["must be a number for >"]} =
               settings_errors(
                 :postgres,
                 Map.merge(valid, %{expected_value: "x", comparison: ">"})
               )

      assert %{expected_value: ["must be a valid regular expression"]} =
               settings_errors(
                 :postgres,
                 Map.merge(valid, %{expected_value: "(", comparison: "regex"})
               )

      assert valid?(:postgres, Map.merge(valid, %{expected_rows: 0, rows_comparison: "<="}))

      assert %{expected_rows: [_]} =
               settings_errors(:postgres, Map.put(valid, :expected_rows, -1))

      assert %{rows_comparison: ["is invalid"]} =
               settings_errors(:postgres, Map.put(valid, :rows_comparison, "contains"))
    end

    test "validates the replication check" do
      valid = valid_settings(:postgres)

      assert %Settings{replication_check: "none", min_standbys: 1, lag_warn_seconds: nil} =
               apply_settings(:postgres, valid)

      for mode <- ["none", "primary", "standby"] do
        assert valid?(:postgres, Map.put(valid, :replication_check, mode))
      end

      assert %{replication_check: ["is invalid"]} =
               settings_errors(:postgres, Map.put(valid, :replication_check, "both"))

      assert %{min_standbys: [_]} = settings_errors(:postgres, Map.put(valid, :min_standbys, -1))

      assert valid?(
               :postgres,
               Map.merge(valid, %{lag_warn_seconds: 10, lag_critical_seconds: 10})
             )

      assert valid?(:postgres, Map.merge(valid, %{lag_critical_bytes: 1_000_000}))

      assert %{lag_critical_seconds: ["must not be less than the warning threshold"]} =
               settings_errors(
                 :postgres,
                 Map.merge(valid, %{lag_warn_seconds: 60, lag_critical_seconds: 30})
               )

      assert %{lag_critical_bytes: ["must not be less than the warning threshold"]} =
               settings_errors(
                 :postgres,
                 Map.merge(valid, %{lag_warn_bytes: 100, lag_critical_bytes: 10})
               )

      assert %{lag_warn_seconds: [_]} =
               settings_errors(:postgres, Map.put(valid, :lag_warn_seconds, 0))
    end
  end

  test "fields not relevant for the type are discarded" do
    settings =
      apply_settings(:tcp, %{
        host: "example.com",
        port: 22,
        url: "https://x",
        assertions: [%{source: "body", comparison: "contains", value: "y"}]
      })

    assert settings.url == nil
    assert settings.assertions == []
  end

  describe "accepted_status_ranges/1 and accepted_status?/2" do
    test "default depends on follow_redirects" do
      assert Settings.accepted_status_ranges(%Settings{follow_redirects: true}) == [200..399]
      assert Settings.accepted_status_ranges(%Settings{follow_redirects: false}) == [200..299]
    end

    test "parses codes and ranges" do
      settings = %Settings{accepted_status_codes: ["200", "300-399"]}
      assert Settings.accepted_status_ranges(settings) == [200..200, 300..399]
      assert Settings.accepted_status?(settings, 200)
      assert Settings.accepted_status?(settings, 302)
      refute Settings.accepted_status?(settings, 204)
    end
  end
end
