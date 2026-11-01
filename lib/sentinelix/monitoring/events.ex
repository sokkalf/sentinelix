defmodule Sentinelix.Monitoring.Events do
  @moduledoc """
  Events posted to monitors by external systems, and the warnings they
  raise.

  Any monitor, whatever its type, can get an event token (see
  `Sentinelix.Monitoring.generate_event_token/1`); `POST
  /api/v1/events/:token` (`SentinelixWeb.EventController`) records an event
  with `record_event/3`. Events show in the monitor's timeline. Their
  severity decides what else happens:

    * `info` (default) – nothing else, the monitor's status is unchanged;
    * `warning` – raises the warning `key` (`""` without a key), see
      `Sentinelix.Monitoring.Warning`, optionally for a `ttl` only;
    * `ok` – clears the warning `key`.

  While a monitor has an active warning, a successful check makes it
  `warning` instead of `up` (see `Sentinelix.Monitoring.Worker`). Several
  independent warnings (e.g. disk space and replication lag) use different
  keys; the monitor is `warning` until all of them are cleared or expired.
  Warnings can also be cleared from the monitor page
  (`clear_warnings/3`).

  Events are pruned with the check results (`prune_events/1`, called by
  `Sentinelix.Stats.Rollup.prune/1`), and deleted with the monitor.

  ## PubSub

  On the monitor's topic (`Sentinelix.Monitoring.subscribe_monitor/1`):

    * `{:event_recorded, %MonitorEvent{}}` – after every recorded event,
    * `{:warnings_changed, monitor_id}` – a warning was raised, cleared or
      expired.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Phoenix.PubSub
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{Monitor, MonitorEvent, Warning}
  alias Sentinelix.Repo

  @pubsub Sentinelix.PubSub
  @default_limit 50

  # Params with a meaning; all others are metadata.
  @fields ~w(title message severity key ttl)
  @ignored_params ~w(token)
  @max_title_length 255
  @max_message_length 4_000
  @max_key_length 100
  @max_metadata_keys 50
  @max_metadata_bytes 8_192
  @max_ttl_seconds 365 * 86_400
  @ttl_units %{"" => 1, "s" => 1, "m" => 60, "h" => 3_600, "d" => 86_400}

  @type monitor_ref :: Monitor.t() | pos_integer()

  ## Recording

  @doc """
  Records an event for a monitor and applies its severity (see the module
  docs). `params` has string (or atom) keys, as received by the endpoint:

    * `"title"` – required, a short description (cut to
      #{@max_title_length} characters),
    * `"message"` – optional, a longer text (cut to #{@max_message_length}
      characters),
    * `"severity"` – `"info"` (default), `"warning"` or `"ok"`,
    * `"key"` – the warning a `warning` or `ok` event raises or clears
      (default `""`; ignored for `info`),
    * `"ttl"` – `warning` only: the warning expires after this long unless
      raised again, in seconds or with a unit (`"90"`, `"30m"`, `"12h"`,
      `"7d"`), at most 365 days,
    * any other params – stored as `metadata` (at most
      #{@max_metadata_keys} keys and #{@max_metadata_bytes} bytes of JSON).

  The monitor's worker re-evaluates its status right away. Returns the
  event with the monitor's resulting status (see `current_status/1`), or
  an error changeset for invalid params (see `error_message/1`).

  ## Options

    * `:now` – when the event occurred (default now)
  """
  @spec record_event(Monitor.t(), map(), keyword()) ::
          {:ok, MonitorEvent.t(), atom()} | {:error, Changeset.t()}
  def record_event(%Monitor{} = monitor, params, opts \\ []) when is_map(params) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, attrs} <- cast_event(params),
         {:ok, event} <- insert_event(monitor, attrs, now) do
      broadcast(monitor, {:event_recorded, event})

      if event.severity == :info do
        {:ok, event, current_status(monitor)}
      else
        broadcast(monitor, {:warnings_changed, monitor.id})
        {:ok, event, warnings_changed(monitor)}
      end
    end
  end

  defp insert_event(monitor, attrs, now) do
    Repo.transaction(fn ->
      event = insert_event!(monitor, attrs, now)
      change_warning(monitor, attrs, now)
      event
    end)
  end

  defp insert_event!(monitor, attrs, now) do
    Repo.insert!(%MonitorEvent{
      monitor_id: monitor.id,
      occurred_at: now,
      severity: attrs.severity,
      key: attrs.key,
      title: attrs.title,
      message: attrs.message,
      metadata: attrs.metadata
    })
  end

  defp change_warning(monitor, %{severity: :warning} = attrs, now) do
    expires_at = attrs.ttl && DateTime.add(now, attrs.ttl, :second)

    Repo.insert!(
      %Warning{
        monitor_id: monitor.id,
        key: attrs.key,
        title: attrs.title,
        message: attrs.message,
        raised_at: now,
        expires_at: expires_at
      },
      on_conflict: {:replace, [:title, :message, :raised_at, :expires_at, :updated_at]},
      conflict_target: [:monitor_id, :key]
    )
  end

  defp change_warning(monitor, %{severity: :ok, key: key}, _now) do
    Repo.delete_all(from w in Warning, where: w.monitor_id == ^monitor.id and w.key == ^key)
  end

  defp change_warning(_monitor, _attrs, _now), do: :ok

  ## Params

  defp cast_event(params) do
    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)
    types = %{title: :string, message: :string, severity: :string, key: :string}

    changeset =
      {%{}, types}
      |> Changeset.cast(params, [:title, :message, :severity, :key])
      |> Changeset.update_change(:title, &String.trim/1)
      |> Changeset.validate_required([:title])
      |> Changeset.update_change(:title, &truncate(&1, @max_title_length))
      |> Changeset.update_change(
        :message,
        &(&1 |> String.trim() |> truncate(@max_message_length))
      )
      |> cast_severity()
      |> Changeset.update_change(:key, &String.trim/1)
      |> Changeset.validate_length(:key, max: @max_key_length)
      |> cast_ttl(params["ttl"])
      |> cast_metadata(Map.drop(params, @fields ++ @ignored_params))

    case Changeset.apply_action(changeset, :insert) do
      {:ok, data} ->
        severity = data.severity
        key = if severity == :info, do: nil, else: data[:key] || ""
        message = if data[:message] in [nil, ""], do: nil, else: data.message

        {:ok,
         %{
           title: data.title,
           message: message,
           severity: severity,
           key: key,
           ttl: data[:ttl],
           metadata: data.metadata
         }}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp cast_severity(changeset) do
    case Changeset.get_change(changeset, :severity) do
      nil ->
        Changeset.put_change(changeset, :severity, :info)

      value ->
        case value |> String.trim() |> String.downcase() do
          "" -> Changeset.put_change(changeset, :severity, :info)
          "info" -> Changeset.put_change(changeset, :severity, :info)
          "warning" -> Changeset.put_change(changeset, :severity, :warning)
          "ok" -> Changeset.put_change(changeset, :severity, :ok)
          _ -> Changeset.add_error(changeset, :severity, "must be info, warning or ok")
        end
    end
  end

  defp cast_ttl(changeset, ttl) when ttl in [nil, ""], do: changeset

  defp cast_ttl(changeset, ttl) do
    changeset = %{changeset | types: Map.put(changeset.types, :ttl, :integer)}

    cond do
      Changeset.get_field(changeset, :severity) != :warning ->
        Changeset.add_error(changeset, :ttl, "is only allowed with severity warning")

      seconds = parse_ttl(ttl) ->
        Changeset.put_change(changeset, :ttl, seconds)

      true ->
        Changeset.add_error(
          changeset,
          :ttl,
          "must be a duration up to 365 days, in seconds or with a unit (s, m, h or d)"
        )
    end
  end

  defp parse_ttl(ttl) when is_integer(ttl), do: valid_ttl(ttl)

  defp parse_ttl(ttl) when is_binary(ttl) do
    case Regex.run(~r/\A\s*(\d{1,9})\s*([smhd]?)\s*\z/i, ttl) do
      [_, number, unit] ->
        valid_ttl(String.to_integer(number) * Map.fetch!(@ttl_units, String.downcase(unit)))

      nil ->
        nil
    end
  end

  defp parse_ttl(_ttl), do: nil

  defp valid_ttl(seconds) when seconds > 0 and seconds <= @max_ttl_seconds, do: seconds
  defp valid_ttl(_seconds), do: nil

  defp cast_metadata(changeset, metadata) do
    changeset = %{changeset | types: Map.put(changeset.types, :metadata, :map)}

    cond do
      map_size(metadata) > @max_metadata_keys ->
        Changeset.add_error(changeset, :metadata, "can have at most #{@max_metadata_keys} fields")

      byte_size(Jason.encode!(metadata)) > @max_metadata_bytes ->
        Changeset.add_error(changeset, :metadata, "must be at most #{@max_metadata_bytes} bytes")

      true ->
        Changeset.put_change(changeset, :metadata, metadata)
    end
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  @doc """
  A one-line description of the errors of an invalid event (as returned
  by `record_event/3`), e.g. `"title can't be blank"`.
  """
  @spec error_message(Changeset.t()) :: String.t()
  def error_message(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.sort()
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  ## Warnings

  @doc """
  The active (not expired) warnings of a monitor, oldest first.

  ## Options

    * `:now` – default now
  """
  @spec active_warnings(monitor_ref(), keyword()) :: [Warning.t()]
  def active_warnings(monitor, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    id = monitor_id(monitor)

    Warning
    |> where([w], w.monitor_id == ^id)
    |> where([w], is_nil(w.expires_at) or w.expires_at > ^now)
    |> order_by([w], asc: w.raised_at, asc: w.id)
    |> Repo.all()
  end

  @doc """
  Clears warnings of a monitor by hand (from the monitor page): all of
  them, or those with the given keys. Each cleared warning is logged as an
  `ok` event ("Warning cleared: <title>").

  ## Options

    * `:by` – who cleared them, stored as `cleared_by` in the events'
      metadata
    * `:now` – default now
  """
  @spec clear_warnings(Monitor.t(), :all | [String.t()], keyword()) :: {:ok, [Warning.t()]}
  def clear_warnings(%Monitor{} = monitor, keys \\ :all, opts \\ []) do
    metadata = if by = opts[:by], do: %{"cleared_by" => by}, else: %{}

    query =
      case keys do
        :all -> from(w in Warning, where: w.monitor_id == ^monitor.id)
        keys -> from(w in Warning, where: w.monitor_id == ^monitor.id and w.key in ^keys)
      end

    remove_warnings(monitor, query, "Warning cleared", metadata, opts)
  end

  @doc """
  Removes the warnings of a monitor that have expired; each is logged as
  an `ok` event ("Warning expired: <title>"). Run by the monitor's worker
  when the next warning expires.

  ## Options

    * `:now` – default now
    * `:notify` – whether to tell the monitor's worker (default `true`; the
      worker itself passes `false`)
  """
  @spec expire_warnings(monitor_ref(), keyword()) :: {:ok, [Warning.t()]}
  def expire_warnings(monitor, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    id = monitor_id(monitor)
    query = from(w in Warning, where: w.monitor_id == ^id and w.expires_at <= ^now)
    remove_warnings(id, query, "Warning expired", %{}, Keyword.put(opts, :now, now))
  end

  defp remove_warnings(monitor, query, verb, metadata, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    id = monitor_id(monitor)

    {:ok, {removed, events}} =
      Repo.transaction(fn ->
        {_count, removed} = query |> select([w], w) |> Repo.delete_all()

        events =
          removed
          |> Enum.sort_by(&{DateTime.to_unix(&1.raised_at, :microsecond), &1.id})
          |> Enum.map(fn warning ->
            insert_event!(
              %Monitor{id: id},
              %{
                severity: :ok,
                key: warning.key,
                title: truncate("#{verb}: #{warning.title}", @max_title_length),
                message: nil,
                metadata: metadata
              },
              now
            )
          end)

        {removed, events}
      end)

    if removed != [] do
      Enum.each(events, &broadcast(id, {:event_recorded, &1}))
      broadcast(id, {:warnings_changed, id})
      if Keyword.get(opts, :notify, true), do: warnings_changed(id)
    end

    {:ok, removed}
  end

  ## Status

  # Tells the monitor's worker that its warnings changed and returns the
  # resulting status.
  defp warnings_changed(monitor), do: current_status(monitor)

  @doc """
  The status of a monitor as its latest check result has it (`:pending`
  without one).
  """
  @spec current_status(monitor_ref()) :: atom()
  def current_status(monitor) do
    case Monitoring.get_latest_result(monitor) do
      nil -> :pending
      result -> result.status
    end
  end

  ## Listing and pruning

  @doc """
  The most recent events of a monitor, newest first.
  """
  @spec list_events(monitor_ref(), pos_integer()) :: [MonitorEvent.t()]
  def list_events(monitor, limit \\ @default_limit) do
    id = monitor_id(monitor)

    MonitorEvent
    |> where([e], e.monitor_id == ^id)
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Deletes the events that occurred before `cutoff`. Returns how many.
  """
  @spec prune_events(DateTime.t()) :: non_neg_integer()
  def prune_events(%DateTime{} = cutoff) do
    {count, _} = Repo.delete_all(from e in MonitorEvent, where: e.occurred_at < ^cutoff)
    count
  end

  defp broadcast(monitor, message),
    do: PubSub.broadcast(@pubsub, Monitoring.monitor_topic(monitor_id(monitor)), message)

  defp monitor_id(%Monitor{id: id}) when is_integer(id), do: id
  defp monitor_id(id) when is_integer(id), do: id
end
