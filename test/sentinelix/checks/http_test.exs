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
end
