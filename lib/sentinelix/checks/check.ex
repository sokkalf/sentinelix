defmodule Sentinelix.Checks.Check do
  @moduledoc """
  Behaviour for check types.

  A check performs a single probe for a monitor and reports whether the
  target is `:up` or `:down`. It is stateless: retries, scheduling, timeouts,
  persistence and status transitions are handled by
  `Sentinelix.Monitoring.Worker`, which runs `c:run/1` in a separate task
  and kills it after the monitor's `timeout_ms`.

  ## Result details

    * `:response_time_ms` – how long the probe took. When missing, the worker
      fills in the wall-clock duration of `c:run/1`.
    * `:status_code` – a protocol status code (e.g. the HTTP status), if any.
    * `:message` – a short human readable description of the outcome.
    * `:warning` – `true` when the target is up but needs attention (e.g. a
      TLS certificate close to expiry). The worker turns changes of this flag
      into `:warning_raised` / `:warning_cleared` events, see
      `Sentinelix.Monitoring.subscribe_status_changes/0`.
    * `:meta` – free-form, check-specific data (e.g. `%{days_remaining: 12}`)
      that is passed on in telemetry metadata and status change events but
      not persisted.

  ## Adding a check type

  Implement this behaviour and register the module for its monitor type in
  `Sentinelix.Checks`. Monitors whose type has no registered check are not
  started.
  """

  alias Sentinelix.Monitoring.Monitor

  @type status :: :up | :down

  @type details :: %{
          optional(:response_time_ms) => non_neg_integer() | nil,
          optional(:status_code) => non_neg_integer() | nil,
          optional(:message) => String.t() | nil,
          optional(:warning) => boolean(),
          optional(:meta) => map()
        }

  @type result :: {status(), details()}

  @doc """
  Probes the target of `monitor` once.

  Must return `{:up, details}` or `{:down, details}`. Expected failures
  (connection refused, unexpected status, …) should be returned as `:down`
  with a message rather than raised; a raise or exit is still recorded as
  `:down` by the worker.
  """
  @callback run(monitor :: Monitor.t()) :: result()

  @doc """
  Whether the check is passive (optional, defaults to `false`).

  Passive checks don't probe their target: results are delivered to the
  worker from outside with `Sentinelix.Monitoring.Worker.push/3` (e.g. by
  the push endpoint), and `c:run/1` is only called when no result arrived
  in time. See "Passive checks" in `Sentinelix.Monitoring.Worker`.
  """
  @callback passive?() :: boolean()

  @optional_callbacks passive?: 0
end
