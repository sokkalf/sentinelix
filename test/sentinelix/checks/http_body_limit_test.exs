defmodule Sentinelix.Checks.HTTPBodyLimitTest do
  # Not async: changes the application environment of the HTTP check.
  use ExUnit.Case, async: false

  alias Sentinelix.Checks.HTTP
  alias Sentinelix.Monitoring.Monitor

  setup do
    config = Application.get_env(:sentinelix, HTTP)
    Application.put_env(:sentinelix, HTTP, Keyword.put(config, :max_body_bytes, 10))
    on_exit(fn -> Application.put_env(:sentinelix, HTTP, config) end)
  end

  defp check(assertions) do
    %Monitor{}
    |> Monitor.changeset(%{
      name: "test",
      type: :http,
      settings: %{url: "https://example.com/health", assertions: assertions}
    })
    |> Ecto.Changeset.apply_action!(:insert)
    |> HTTP.run()
  end

  defp a(source, path, comparison, value \\ nil),
    do: %{source: source, path: path, comparison: comparison, value: value}

  test "a body over the limit fails body and JSON assertions" do
    Req.Test.stub(HTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-version", "1.2.3")
      |> Plug.Conn.send_resp(200, ~s({"status": "ok"}))
    end)

    assert {:up, _} = check([a("header", "x-version", "exists")])

    assert {:down, %{message: "Response body exceeds 10 bytes"}} =
             check([a("body", nil, "contains", "status")])

    assert {:down, %{message: "Response body exceeds 10 bytes"}} =
             check([a("json", "status", "exists")])

    Req.Test.stub(HTTP, &Plug.Conn.send_resp(&1, 200, "0123456789"))
    assert {:up, _} = check([a("body", nil, "equals", "0123456789")])
  end
end
