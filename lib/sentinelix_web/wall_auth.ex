defmodule SentinelixWeb.WallAuth do
  @moduledoc """
  Access to wall displays (`/wall/<token>`, `SentinelixWeb.WallLive`) with
  a display token (`Sentinelix.DisplayTokens`) instead of a user session.

  As a plug (the router's `:wall` pipeline), for the page load:

    * Counts the request in the `:wall` rate limit bucket of the client IP
      (`Sentinelix.RateLimit`, `WALL_RATE_LIMIT`); over the limit is a 429
      with `retry-after` that reloads itself when the limit allows.
    * Verifies the token: unknown, malformed, expired and revoked tokens
      all get the same plain 404 as any unknown page, so they can't be told
      apart.
    * Logs the request without the token: the endpoint doesn't log
      `/wall/*` paths (`SentinelixWeb.Endpoint.log_level/1`), this plug logs
      `GET /wall/[FILTERED]` and the response status instead. `token`
      parameters are filtered (`:filter_parameters`), so LiveView's and
      the router's debug logs don't show it either.
    * Sends `cache-control: no-store` and `x-robots-tag: noindex`; the
      pipeline sets `referrer-policy: no-referrer`, so the token in the
      URL isn't sent on to other sites.

  As an `on_mount` hook (`on_mount/4`) it verifies the token again on
  every mount, so a LiveView reconnecting after a network loss or a
  restart only comes back while the token is valid. Connected mounts
  (every reconnect) count against the rate limit too. When either fails,
  the LiveView redirects to its own URL, which the plug then refuses.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Phoenix.LiveView
  alias Sentinelix.{DisplayTokens, RateLimit}
  alias SentinelixWeb.Plugs.ClientIP

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = log_request(conn)

    with :ok <- rate_limit(conn),
         {:ok, _display_token} <- verify(conn) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-robots-tag", "noindex, nofollow")
    end
  end

  defp log_request(conn) do
    start = System.monotonic_time()
    Logger.info([conn.method, " /wall/[FILTERED]"])

    register_before_send(conn, fn conn ->
      Logger.info(fn ->
        duration =
          System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)

        ["Sent ", Integer.to_string(conn.status), " in ", Integer.to_string(duration), "ms"]
      end)

      conn
    end)
  end

  defp rate_limit(conn) do
    case RateLimit.check(:wall, conn.remote_ip) do
      :ok ->
        :ok

      {:error, retry_after_ms} ->
        seconds = Integer.to_string(div(retry_after_ms + 999, 1000))

        # The display reloads itself once it may again.
        conn
        |> put_resp_header("retry-after", seconds)
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/html")
        |> send_resp(429, """
        <!DOCTYPE html>
        <html><head><meta http-equiv="refresh" content="#{seconds}"><title>Too Many Requests</title></head>
        <body>Too Many Requests</body></html>
        """)
        |> halt()
    end
  end

  defp verify(%{path_params: %{"token" => token}} = conn) do
    case DisplayTokens.verify_token(token) do
      {:ok, display_token} -> {:ok, display_token}
      :error -> not_found(conn)
    end
  end

  defp verify(conn), do: not_found(conn)

  # Exactly what any unknown page gets.
  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> Phoenix.Controller.put_root_layout(false)
    |> Phoenix.Controller.put_view(html: SentinelixWeb.ErrorHTML)
    |> Phoenix.Controller.render("404.html")
    |> halt()
  end

  @doc """
  Verifies the display token of a wall LiveView on mount: assigns
  `:display_token`, or redirects to the page itself (where the plug
  answers 404 or 429). See the module docs.
  """
  def on_mount(:default, %{"token" => token}, _session, socket) do
    path = "/wall/" <> URI.encode(token, &URI.char_unreserved?/1)

    with :ok <- connected_rate_limit(socket),
         {:ok, display_token} <- DisplayTokens.verify_token(token) do
      {:cont, socket |> LiveView.put_private(:wall_path, path) |> assign_token(display_token)}
    else
      _refused -> refuse(socket, path)
    end
  end

  def on_mount(:default, _params, _session, socket), do: refuse(socket, "/wall/-")

  defp assign_token(socket, display_token),
    do: Phoenix.Component.assign(socket, :display_token, display_token)

  # The page load was counted by the plug.
  defp connected_rate_limit(socket) do
    if LiveView.connected?(socket) do
      ip =
        ClientIP.from_connect_info(
          LiveView.get_connect_info(socket, :peer_data),
          LiveView.get_connect_info(socket, :x_headers)
        )

      RateLimit.check(:wall, ip || :unknown)
    else
      :ok
    end
  end

  # Only a connected mount can redirect; the plug has already refused a
  # page load with an invalid token (this is for one revoked in between).
  defp refuse(socket, path) do
    if LiveView.connected?(socket),
      do: {:halt, LiveView.redirect(socket, to: path)},
      else: raise(SentinelixWeb.WallAuth.NotFoundError)
  end

  defmodule NotFoundError do
    @moduledoc "A wall display without a valid token (rendered as 404)."
    defexception message: "not found", plug_status: 404
  end
end
