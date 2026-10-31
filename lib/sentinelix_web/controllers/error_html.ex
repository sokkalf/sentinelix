defmodule SentinelixWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use SentinelixWeb, :html

  # If you want to customize your error pages,
  # uncomment the embed_templates/1 call below
  # and add pages to the error directory:
  #
  #   * lib/sentinelix_web/controllers/error_html/404.html.heex
  #   * lib/sentinelix_web/controllers/error_html/500.html.heex
  #
  # embed_templates "error_html/*"

  @wall_retry_seconds 30

  # A wall display (SentinelixWeb.WallLive) that hits a server error, e.g.
  # while reconnecting during a database outage, reloads itself after a
  # while instead of showing the error until someone reloads it.
  def render(template, %{conn: %Plug.Conn{path_info: ["wall" | _]}, status: status})
      when status >= 500 do
    message = Phoenix.Controller.status_message_from_template(template)

    raw("""
    <!DOCTYPE html>
    <html><head><meta http-equiv="refresh" content="#{@wall_retry_seconds}"><title>#{message}</title></head>
    <body>#{message}</body></html>
    """)
  end

  # The default is to render a plain text page based on
  # the template name. For example, "404.html" becomes
  # "Not Found".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
