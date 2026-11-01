# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It creates a few example monitors, but only when there are no monitors yet,
# so it is safe to run more than once.

alias Sentinelix.Monitoring

if Monitoring.list_monitors() == [] do
  examples = [
    %{
      name: "Example.com",
      type: :http,
      description: "Example HTTP monitor",
      labels: %{"env" => "example", "service" => "example.com"},
      settings: %{url: "https://example.com"}
    },
    %{
      name: "Example.com certificate",
      type: :cert,
      description: "Warns when the TLS certificate is about to expire",
      labels: %{"env" => "example", "service" => "example.com"},
      interval_seconds: 3600,
      settings: %{host: "example.com", port: 443, cert_warn_days: 30, cert_critical_days: 7}
    },
    %{
      name: "Example.com content",
      type: :http,
      labels: %{"env" => "example", "service" => "example.com"},
      enabled: false,
      interval_seconds: 300,
      settings: %{
        url: "https://example.com",
        assertions: [
          %{source: "body", comparison: "contains", value: "Example Domain"},
          %{source: "header", path: "content-type", comparison: "contains", value: "text/html"}
        ]
      }
    }
  ]

  for attrs <- examples do
    {:ok, monitor} = Monitoring.create_monitor(attrs)
    IO.puts("Created monitor ##{monitor.id}: #{monitor.name}")
  end
end
