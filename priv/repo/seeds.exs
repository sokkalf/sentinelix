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
      tags: ["example"],
      settings: %{url: "https://example.com"}
    },
    %{
      name: "Example.com certificate",
      type: :cert,
      description: "Warns when the TLS certificate is about to expire",
      tags: ["example"],
      interval_seconds: 3600,
      settings: %{host: "example.com", port: 443, cert_warn_days: 30, cert_critical_days: 7}
    },
    %{
      name: "Example.com keyword",
      type: :keyword,
      tags: ["example"],
      enabled: false,
      interval_seconds: 300,
      settings: %{url: "https://example.com", keyword: "Example Domain"}
    }
  ]

  for attrs <- examples do
    {:ok, monitor} = Monitoring.create_monitor(attrs)
    IO.puts("Created monitor ##{monitor.id}: #{monitor.name}")
  end
end
