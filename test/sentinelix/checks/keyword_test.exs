defmodule Sentinelix.Checks.KeywordTest do
  use ExUnit.Case, async: true

  alias Sentinelix.Checks.{HTTP, Keyword}
  alias Sentinelix.Monitoring.Monitor

  defp monitor(settings) do
    %Monitor{}
    |> Monitor.changeset(%{
      name: "test",
      type: :keyword,
      settings: Map.merge(%{url: "https://example.com/health", keyword: "OK"}, settings)
    })
    |> Ecto.Changeset.apply_action!(:insert)
  end

  defp respond(status \\ 200, body) do
    Req.Test.stub(HTTP, &Plug.Conn.send_resp(&1, status, body))
  end

  describe "keyword" do
    test "is up when the body contains the keyword" do
      respond("<p>Status: OK</p>")

      assert {:up, details} = Keyword.run(monitor(%{}))
      assert details.status_code == 200
      assert details.message == ~s(Keyword "OK" found)
      assert is_integer(details.response_time_ms)
    end

    test "is down when the body lacks the keyword" do
      respond("<p>Status: degraded</p>")

      assert {:down, %{status_code: 200, message: ~s(Keyword "OK" not found)}} =
               Keyword.run(monitor(%{}))
    end

    test "is case-sensitive by default" do
      respond("all ok")
      assert {:down, _} = Keyword.run(monitor(%{}))
      assert {:up, _} = Keyword.run(monitor(%{case_sensitive: false}))
    end

    test "can be inverted" do
      respond("Fatal error")
      monitor = monitor(%{keyword: "error", invert_keyword: true, case_sensitive: false})

      assert {:down, %{message: ~s(Keyword "error" found but must not be present)}} =
               Keyword.run(monitor)

      respond("all good")
      assert {:up, %{message: ~s(Keyword "error" not found, as expected)}} = Keyword.run(monitor)
    end

    test "an unaccepted status is down regardless of the body" do
      respond(503, "OK")

      assert {:down, %{status_code: 503, message: "Unexpected status 503" <> _}} =
               Keyword.run(monitor(%{}))

      # ... also when inverted.
      assert {:down, %{status_code: 503}} = Keyword.run(monitor(%{invert_keyword: true}))
    end

    test "a transport error is down" do
      Req.Test.stub(HTTP, &Req.Test.transport_error(&1, :econnrefused))
      assert {:down, %{message: message}} = Keyword.run(monitor(%{}))
      assert message =~ "connection refused"
    end

    test "long keywords are shortened in the message" do
      keyword = String.duplicate("x", 300)
      respond("nothing")

      assert {:down, %{message: message}} = Keyword.run(monitor(%{keyword: keyword}))
      assert String.length(message) < 150
    end
  end

  describe "json path" do
    @body ~s({"status": "UP", "checks": [{"name": "db", "healthy": true, "latency": 12}], "x": null})

    test "is up when the value at the path equals the keyword" do
      respond(@body)

      assert {:up, %{message: ~s(status is "UP")}} =
               Keyword.run(monitor(%{json_path: "status", keyword: "UP"}))

      assert {:up, _} = Keyword.run(monitor(%{json_path: "$.checks.0.name", keyword: "db"}))
    end

    test "compares non-string values by their JSON encoding" do
      respond(@body)

      assert {:up, _} = Keyword.run(monitor(%{json_path: "checks.0.healthy", keyword: "true"}))
      assert {:up, _} = Keyword.run(monitor(%{json_path: "checks.0.latency", keyword: "12"}))
      assert {:up, _} = Keyword.run(monitor(%{json_path: "x", keyword: "null"}))
    end

    test "is down when the value differs" do
      respond(@body)

      assert {:down, %{message: ~s(status is "UP", expected "DOWN")}} =
               Keyword.run(monitor(%{json_path: "status", keyword: "DOWN"}))
    end

    test "honours case sensitivity and inversion" do
      respond(@body)

      assert {:down, _} = Keyword.run(monitor(%{json_path: "status", keyword: "up"}))

      assert {:up, _} =
               Keyword.run(monitor(%{json_path: "status", keyword: "up", case_sensitive: false}))

      assert {:down, %{message: ~s(status is "UP" but must not be)}} =
               Keyword.run(monitor(%{json_path: "status", keyword: "UP", invert_keyword: true}))

      assert {:up, _} =
               Keyword.run(monitor(%{json_path: "status", keyword: "DOWN", invert_keyword: true}))
    end

    test "a missing path is down" do
      respond(@body)

      for path <- ["missing", "checks.5.name", "checks.name", "status.inner"] do
        assert {:down, %{message: message}} =
                 Keyword.run(monitor(%{json_path: path, keyword: "x"}))

        assert message == "JSON path #{path} not found in the response"
      end
    end

    test "a non-JSON body is down" do
      respond("<html>OK</html>")

      assert {:down, %{message: "Response body is not valid JSON"}} =
               Keyword.run(monitor(%{json_path: "status", keyword: "OK"}))
    end
  end
end
