defmodule Sentinelix.Monitoring.Export do
  @moduledoc """
  Exports monitors as YAML, to keep a setup in git or move it to another
  instance. `Sentinelix.Monitoring.Import` reads the same format back.

      mix sentinelix.export > monitors.yaml
      mix sentinelix.export --selector "env=prod" --output prod.yaml
      bin/export_monitors --selector "env=prod" > prod.yaml   # in a release

  ## Format

      # Sentinelix monitors
      version: 1
      monitors:
        - name: Router
          type: ping
          enabled: true
          interval_seconds: 60
          retry_interval_seconds: 60
          max_retries: 0
          timeout_ms: 30000
          settings:
            host: "10.0.0.1"
        - name: Shop API
          type: http
          enabled: true
          interval_seconds: 30
          retry_interval_seconds: 30
          max_retries: 2
          timeout_ms: 10000
          description: The public API
          parent: Router
          labels:
            env: prod
            legacy: ""
          channels:
            - Ops email
          settings:
            url: https://shop.example.com/health
            method: GET
            follow_redirects: true
            max_redirects: 10
            verify_tls: true

    * `version` – the format version, `1`. An import rejects other versions,
      so a later, incompatible format can't be misread.
    * `monitors` – ordered by name. Each monitor has its `name` and `type`,
      the schedule fields, and – when set – a `description`, its `parent`
      (by name), its user `labels` (a label without a value is `""`; the
      automatic labels are derived and not exported) and its notification
      `channels` (by name). `settings` holds the type's settings (see
      `Sentinelix.Monitoring.Settings`) that have a value.

  Names are the key: the import matches monitors, parents and channels by
  name, so monitor names need to be unique for a file to be imported.

  ## What isn't exported

    * **Secrets** (`Sentinelix.Monitoring.Monitor.secret_fields/1`, e.g. the
      password of a PostgreSQL monitor) are never exported.
    * **Push tokens** are credentials (anyone with the token can report a
      push monitor up) and are left out unless `push_tokens: true` is
      given, e.g. to move push monitors to another instance without
      reconfiguring the pushers.
    * The runtime state (status, check results, incidents), maintenance
      windows and status pages.

  The output only depends on the monitors, so exporting the same setup
  twice gives the same file.
  """

  import Ecto.Query, only: [from: 2]

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{Monitor, Selector, Settings}
  alias Sentinelix.Notifications.Channel
  alias Sentinelix.{Repo, YAML}

  @version 1
  @header "# Sentinelix monitors\n"

  @doc "The format version written by `to_yaml/2`."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  Exports the monitors matching a selector (all monitors by default) as
  YAML.

  ## Options

    * `:selector` – a `Sentinelix.Monitoring.Selector` or its text; label
      and name terms only (a status isn't stored).
    * `:push_tokens` – include the push tokens of push monitors (default
      `false`).
  """
  @spec export(keyword()) :: {:ok, String.t()} | {:error, Selector.Error.t()}
  def export(opts \\ []) do
    with {:ok, selector} <- selector(opts[:selector]) do
      {:ok, [selector: selector] |> Monitoring.list_monitors() |> to_yaml(opts)}
    end
  end

  defp selector(nil), do: {:ok, %Selector{}}
  defp selector(selector), do: Selector.validate(selector, allow: [:labels, :name])

  @doc """
  The YAML document for the given monitors, in the order given. Takes the
  `:push_tokens` option of `export/1`.
  """
  @spec to_yaml([Monitor.t()], keyword()) :: String.t()
  def to_yaml(monitors, opts \\ []) do
    channels = channel_names(monitors)
    parents = parent_names(monitors)

    document = [
      {"version", @version},
      {"monitors", Enum.map(monitors, &monitor(&1, channels, parents, opts))}
    ]

    @header <> YAML.encode(document)
  end

  defp monitor(monitor, channels, parents, opts) do
    [
      {"name", monitor.name},
      {"type", Atom.to_string(monitor.type)},
      {"enabled", monitor.enabled},
      {"interval_seconds", monitor.interval_seconds},
      {"retry_interval_seconds", monitor.retry_interval_seconds},
      {"max_retries", monitor.max_retries},
      {"timeout_ms", monitor.timeout_ms},
      {"description", monitor.description},
      {"parent", parents[monitor.parent_id]},
      {"labels", monitor.labels || %{}},
      {"channels", Map.get(channels, monitor.id, [])},
      {"settings", settings(monitor, opts)}
    ]
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
  end

  defp settings(%Monitor{type: type, settings: settings}, opts) do
    push_tokens? = Keyword.get(opts, :push_tokens, false)

    for field <- Settings.fields_for(type),
        field != :push_token or push_tokens?,
        value = settings && Map.get(settings, field),
        not blank?(value),
        do: {Atom.to_string(field), value}
  end

  defp blank?(value), do: value in [nil, "", [], %{}]

  # monitor id => channel names, sorted.
  defp channel_names(monitors) do
    ids = Enum.map(monitors, & &1.id)

    from(mc in "monitor_notification_channels",
      join: c in Channel,
      on: c.id == mc.channel_id,
      where: mc.monitor_id in ^ids,
      order_by: [asc: fragment("lower(?)", c.name), asc: c.name, asc: c.id],
      select: {mc.monitor_id, c.name}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # parent id => name, also for parents that aren't exported.
  defp parent_names(monitors) do
    ids = monitors |> Enum.map(& &1.parent_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(m in Monitor, where: m.id in ^ids, select: {m.id, m.name})
    |> Repo.all()
    |> Map.new()
  end
end
