defmodule Sentinelix.Checks.HTTPTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Checks.HTTP
  alias Sentinelix.Monitoring.Monitor

  defp monitor(settings, attrs \\ %{}) do
    %Monitor{}
    |> Monitor.changeset(
      Map.merge(
        %{
          name: "test",
          type: :http,
          settings: Map.put_new(settings, :url, "https://example.com/health")
        },
        attrs
      )
    )
    |> Ecto.Changeset.apply_action!(:insert)
  end

  defp stub(fun), do: Req.Test.stub(HTTP, fun)

  defp redirect(conn, status, location) do
    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(status, "")
  end

  test "a 200 response is up" do
    stub(&Plug.Conn.send_resp(&1, 200, "fine"))

    assert {:up, details} = HTTP.run(monitor(%{}))
    assert details.status_code == 200
    assert details.message == "200 OK"
    assert is_integer(details.response_time_ms) and details.response_time_ms >= 0
  end

  test "an error status is down" do
    stub(&Plug.Conn.send_resp(&1, 503, "nope"))

    assert {:down, %{status_code: 503, message: message}} = HTTP.run(monitor(%{}))
    assert message =~ "503 Service Unavailable"
    assert message =~ "accepted: 200-399"
  end

  test "sends method, headers, body and the Sentinelix user agent" do
    test_pid = self()

    stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.req_headers, body})
      Plug.Conn.send_resp(conn, 201, "")
    end)

    monitor =
      monitor(%{
        url: "https://example.com/api/ping",
        method: "post",
        headers: %{"X-Token" => "secret", "Content-Type" => "application/json"},
        body: ~s({"ping":true})
      })

    assert {:up, %{status_code: 201}} = HTTP.run(monitor)
    assert_received {:request, "POST", "/api/ping", headers, ~s({"ping":true})}
    assert {"x-token", "secret"} in headers
    assert {"content-type", "application/json"} in headers
    assert {"user-agent", "Sentinelix/" <> _} = List.keyfind(headers, "user-agent", 0)
  end

  test "a custom user agent header wins" do
    stub(fn conn ->
      assert Plug.Conn.get_req_header(conn, "user-agent") == ["custom/1.0"]
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:up, _} = HTTP.run(monitor(%{headers: %{"User-Agent" => "custom/1.0"}}))
  end

  describe "redirects" do
    test "are followed, resolving relative Location headers" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:path, conn.request_path})

        case conn.request_path do
          "/a/start" -> redirect(conn, 301, "next")
          "/a/next" -> redirect(conn, 302, "/final")
          "/final" -> Plug.Conn.send_resp(conn, 200, "")
        end
      end)

      assert {:up, %{status_code: 200}} = HTTP.run(monitor(%{url: "https://example.com/a/start"}))
      assert_received {:path, "/a/start"}
      assert_received {:path, "/a/next"}
      assert_received {:path, "/final"}
    end

    test "are limited to max_redirects" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, :hop)
        redirect(conn, 302, "/loop")
      end)

      assert {:down, %{message: "Too many redirects (more than 3)"}} =
               HTTP.run(monitor(%{max_redirects: 3}))

      # The initial request plus three redirects, then it stops.
      for _ <- 1..4, do: assert_received(:hop)
      refute_received :hop
    end

    test "are not followed when disabled, and 3xx is then not accepted by default" do
      stub(&redirect(&1, 302, "/elsewhere"))

      assert {:down, %{status_code: 302, message: message}} =
               HTTP.run(monitor(%{follow_redirects: false}))

      assert message =~ "accepted: 200-299"
    end
  end

  describe "accepted status codes" do
    test "custom codes and ranges" do
      stub(&Plug.Conn.send_resp(&1, 418, ""))

      assert {:up, %{status_code: 418}} = HTTP.run(monitor(%{accepted_status_codes: ["418"]}))

      assert {:up, _} =
               HTTP.run(monitor(%{accepted_status_codes: ["200-299", "400-499"]}))

      assert {:down, %{message: message}} =
               HTTP.run(monitor(%{accepted_status_codes: ["200", "300-399"]}))

      assert message =~ "accepted: 200, 300-399"
    end

    test "a redirect can be accepted when not following redirects" do
      stub(&redirect(&1, 301, "/elsewhere"))

      assert {:up, %{status_code: 301}} =
               HTTP.run(monitor(%{follow_redirects: false, accepted_status_codes: ["300-399"]}))
    end
  end

  test "transport errors are down" do
    stub(&Req.Test.transport_error(&1, :econnrefused))
    assert {:down, %{message: "connection refused"} = details} = HTTP.run(monitor(%{}))
    refute Map.has_key?(details, :status_code)

    stub(&Req.Test.transport_error(&1, :timeout))
    assert {:down, %{message: "Timed out"}} = HTTP.run(monitor(%{}))
  end

  describe "connect options" do
    test "TLS verification is only disabled for https when verify_tls is off" do
      opts = fn monitor, url ->
        request = HTTP.build_request(monitor)
        {_name, step} = List.keyfind(request.request_steps, :sentinelix_connect_options, 0)
        step.(%{request | url: URI.parse(url)}).options.connect_options
      end

      insecure = monitor(%{verify_tls: false}, %{timeout_ms: 1234})

      assert opts.(insecure, "https://x") == [
               timeout: 1234,
               transport_opts: [log_level: :error, verify: :verify_none]
             ]

      # :gen_tcp rejects TLS options, e.g. after a redirect to plain http.
      assert opts.(insecure, "http://x") == [timeout: 1234, transport_opts: []]

      assert opts.(monitor(%{}), "https://x")[:transport_opts] == [log_level: :error]
    end
  end

  describe "assertions" do
    @json ~s({"status": "ok", "queue": {"depth": 250}, "checks": [{"name": "db", "healthy": true}], "x": null})

    defp json_response(conn, body \\ @json) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.put_resp_header("x-version", "1.2.3")
      |> Plug.Conn.send_resp(200, body)
    end

    defp check(assertions, settings \\ %{}) do
      HTTP.run(monitor(Map.put(settings, :assertions, assertions)))
    end

    defp a(source, path, comparison, value \\ nil, opts \\ []) do
      Enum.into(opts, %{source: source, path: path, comparison: comparison, value: value})
    end

    test "all passing is up" do
      stub(&json_response/1)

      assert {:up, %{status_code: 200, message: "200 OK, 3 assertions passed"} = details} =
               check([
                 a("json", "status", "equals", "ok"),
                 a("json", "queue.depth", "<", "1000"),
                 a("header", "content-type", "contains", "application/json")
               ])

      refute Map.has_key?(details, :meta)

      assert {:up, %{message: "200 OK, 1 assertion passed"}} =
               check([a("body", nil, "contains", "queue")])
    end

    test "body comparisons" do
      stub(&Plug.Conn.send_resp(&1, 200, "  healthy\n"))

      for {comparison, value, expected} <- [
            {"equals", "  healthy\n", :up},
            {"equals", "healthy", {:down, ~s(Body is "  healthy\n", expected "healthy")}},
            {"not_equals", "sick", :up},
            {"contains", "healthy", :up},
            {"contains", "OK", {:down, ~s(Body does not contain "OK")}},
            {"not_contains", "error", :up},
            {"not_contains", "heal", {:down, ~s(Body contains "heal")}},
            {"regex", ~S"^\s*healthy\s*$", :up},
            {"regex", "^healthy", {:down, "Body does not match /^healthy/"}},
            {"not_regex", "sick", :up},
            {"not_regex", "heal", {:down, "Body matches /heal/"}},
            {">", "1", {:down, ~s(Body is "  healthy\n", expected > 1 (not a number\))}}
          ] do
        assert_result(check([a("body", nil, comparison, value)]), expected, comparison)
      end
    end

    test "json comparisons" do
      stub(&json_response/1)

      for {path, comparison, value, expected} <- [
            {"status", "equals", "ok", :up},
            {"$.status", "not_equals", "ok",
             {:down, ~s(JSON $.status is "ok", expected anything but "ok")}},
            {"checks.0.name", "contains", "d", :up},
            {"checks.0.name", "not_contains", "x", :up},
            {"checks.0.healthy", "equals", "true", :up},
            {"checks", "regex", ~s("name":"db"), :up},
            {"status", "not_regex", "^fail", :up},
            {"queue.depth", "<", "100", {:down, ~s(JSON queue.depth is "250", expected < 100)}},
            {"queue.depth", "<=", "250", :up},
            {"queue.depth", ">", "249.5", :up},
            {"queue.depth", ">=", "251", {:down, ~s(JSON queue.depth is "250", expected >= 251)}},
            {"x", "equals", "null", :up},
            {"x", "exists", nil, :up},
            {"missing", "not_exists", nil, :up},
            {"checks.5", "exists", nil, {:down, "JSON checks.5 not found"}},
            {"missing", "equals", "x", {:down, "JSON missing not found"}},
            {"status", "not_exists", nil,
             {:down, ~s(JSON status is "ok", expected it not to exist)}}
          ] do
        assert_result(
          check([a("json", path, comparison, value)]),
          expected,
          "#{path} #{comparison}"
        )
      end
    end

    test "header comparisons" do
      stub(fn conn ->
        conn
        |> Plug.Conn.prepend_resp_headers([
          {"vary", "accept"},
          {"vary", "cookie"},
          {"x-count", "42"}
        ])
        |> json_response()
      end)

      for {name, comparison, value, expected} <- [
            {"Content-Type", "contains", "application/json", :up},
            {"x-version", "equals", "1.2.3", :up},
            {"x-version", "not_equals", "1.2.3",
             {:down, ~s(Header x-version is "1.2.3", expected anything but "1.2.3")}},
            {"x-version", "regex", ~S"^1\.", :up},
            {"x-version", "not_regex", ~S"^2\.", :up},
            {"x-version", "not_contains", "beta", :up},
            {"vary", "equals", "accept, cookie", :up},
            {"x-version", "exists", nil, :up},
            {"x-missing", "not_exists", nil, :up},
            {"x-count", ">", "10", :up},
            {"x-count", "<", "10", {:down, ~s(Header x-count is "42", expected < 10)}},
            {"x-missing", "exists", nil, {:down, "Header x-missing missing"}},
            {"x-missing", "contains", "x", {:down, "Header x-missing missing"}},
            {"x-version", "not_exists", nil,
             {:down, ~s(Header x-version is "1.2.3", expected it not to exist)}}
          ] do
        assert_result(
          check([a("header", name, comparison, value)]),
          expected,
          "#{name} #{comparison}"
        )
      end
    end

    defp assert_result(result, :up, label), do: assert({:up, _} = result, label)

    defp assert_result(result, {:down, message}, label) do
      assert {:down, %{message: ^message, meta: %{failed_assertion: 0}}} = result, label
    end

    test "case-insensitive comparisons" do
      stub(&json_response/1)

      assert {:down, _} = check([a("json", "status", "equals", "OK")])
      assert {:up, _} = check([a("json", "status", "equals", "OK", case_sensitive: false)])
      assert {:up, _} = check([a("body", nil, "regex", "STATUS", case_sensitive: false)])
      assert {:down, _} = check([a("body", nil, "regex", "STATUS")])

      assert {:up, _} =
               check([a("header", "content-type", "contains", "JSON", case_sensitive: false)])
    end

    test "the first failing assertion decides" do
      stub(&json_response/1)

      assert {:down, %{message: "Header x-missing missing", meta: %{failed_assertion: 1}}} =
               check([
                 a("json", "status", "equals", "ok"),
                 a("header", "x-missing", "exists"),
                 a("json", "status", "equals", "fail")
               ])
    end

    test "a body that isn't JSON fails JSON assertions" do
      stub(&Plug.Conn.send_resp(&1, 200, "<html>"))

      assert {:down, %{message: "Response body is not valid JSON", meta: %{failed_assertion: 1}}} =
               check([a("body", nil, "contains", "html"), a("json", "status", "exists")])
    end

    test "an unaccepted status fails before the assertions" do
      stub(&Plug.Conn.send_resp(&1, 503, "fine"))

      assert {:down, %{status_code: 503, message: message} = details} =
               check([a("body", nil, "contains", "fine")])

      assert message =~ "Unexpected status 503"
      refute Map.has_key?(details, :meta)
    end

    test "the body is only read when an assertion needs it" do
      stub(&json_response/1)

      assert {:ok, %Req.Response{body: ""}, _} = HTTP.request(monitor(%{}))

      header_only = monitor(%{assertions: [a("header", "x-version", "exists")]})
      assert {:ok, %Req.Response{body: ""}, _} = HTTP.request(header_only)

      with_body = monitor(%{assertions: [a("json", "status", "exists")]})
      assert {:ok, %Req.Response{body: @json}, _} = HTTP.request(with_body)
    end

    test "non-UTF-8 bodies are matched byte-wise" do
      stub(&Plug.Conn.send_resp(&1, 200, <<"OK ", 0xFF, 0xFE>>))

      assert {:up, _} = check([a("body", nil, "regex", "^OK ..$")])
      assert {:up, _} = check([a("body", nil, "contains", "ok", case_sensitive: false)])

      assert {:down, %{message: ~s(Body is "<binary, 5 bytes>", expected "OK")}} =
               check([a("body", nil, "equals", "OK")])
    end

    test "assertions are checked on the final response after redirects" do
      stub(fn
        %{request_path: "/old"} = conn -> redirect(conn, 301, "/new")
        conn -> json_response(conn)
      end)

      assert {:up, _} =
               check([a("json", "status", "equals", "ok")], %{url: "https://example.com/old"})
    end
  end
end
