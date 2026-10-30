defmodule Sentinelix.Monitoring.Monitor do
  @moduledoc """
  A configured monitor (what to check, how often and how).

  Type-specific options live in the `settings` embed, see
  `Sentinelix.Monitoring.Settings`.

  ## Secrets

  Type-specific secrets (see `secret_fields/1`, e.g. the password of a
  PostgreSQL monitor) are not part of `settings`: they are stored encrypted
  in `secrets` (`Sentinelix.EncryptedMap`, string keys) and redacted when
  the monitor is inspected. They are cast from the `"secrets"` param:

    * a blank or missing value keeps the stored secret (forms never render
      secrets back),
    * `"clear_<key>" => "true"` removes it,
    * secrets that don't apply to the monitor's type are dropped, e.g. when
      the type changes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.EncryptedMap
  alias Sentinelix.Monitoring.{CheckResult, Incident, Settings}

  @types [:http, :keyword, :tcp, :ping, :dns, :cert, :push, :postgres]

  @secret_fields %{postgres: ["password"]}

  @min_interval_seconds 20
  @max_interval_seconds 86_400
  @max_retries 100
  @min_timeout_ms 100

  schema "monitors" do
    field :name, :string
    field :type, Ecto.Enum, values: @types
    field :enabled, :boolean, default: true
    field :interval_seconds, :integer, default: 60
    field :retry_interval_seconds, :integer, default: 60
    field :max_retries, :integer, default: 0
    field :timeout_ms, :integer, default: 30_000
    field :description, :string
    field :tags, {:array, :string}, default: []

    embeds_one :settings, Settings, on_replace: :update
    field :secrets, EncryptedMap, default: %{}, redact: true, skip_default_validation: true

    has_many :check_results, CheckResult
    has_many :incidents, Incident

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
  @type type :: :http | :keyword | :tcp | :ping | :dns | :cert | :push | :postgres

  @doc "All monitor types."
  @spec types() :: [type()]
  def types, do: @types

  @doc "The keys of the secrets a monitor type uses."
  @spec secret_fields(type()) :: [String.t()]
  def secret_fields(type), do: Map.get(@secret_fields, type, [])

  @doc """
  The secret `key` of a monitor, or `nil`.
  """
  @spec secret(t(), String.t()) :: String.t() | nil
  def secret(%__MODULE__{secrets: secrets}, key), do: (secrets || %{})[key]

  @doc "Minimum allowed (retry) interval in seconds."
  def min_interval_seconds, do: @min_interval_seconds

  @doc false
  def changeset(monitor, attrs) do
    monitor
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :interval_seconds,
      :retry_interval_seconds,
      :max_retries,
      :timeout_ms,
      :description,
      :tags
    ])
    |> validate_required([
      :name,
      :type,
      :enabled,
      :interval_seconds,
      :retry_interval_seconds,
      :max_retries,
      :timeout_ms
    ])
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:interval_seconds,
      greater_than_or_equal_to: @min_interval_seconds,
      less_than_or_equal_to: @max_interval_seconds
    )
    |> validate_number(:retry_interval_seconds,
      greater_than_or_equal_to: @min_interval_seconds,
      less_than_or_equal_to: @max_interval_seconds
    )
    |> validate_number(:max_retries,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_retries
    )
    |> validate_number(:timeout_ms, greater_than_or_equal_to: @min_timeout_ms)
    |> validate_timeout_within_interval()
    |> update_change(:tags, &normalize_tags/1)
    |> cast_settings()
    |> cast_secrets()
    |> check_constraint(:interval_seconds, name: :interval_seconds_min)
    |> check_constraint(:retry_interval_seconds, name: :retry_interval_seconds_min)
    |> check_constraint(:max_retries, name: :max_retries_non_negative)
    |> check_constraint(:timeout_ms, name: :timeout_ms_positive)
    |> unique_constraint(:settings,
      name: :monitors_push_token_index,
      message: "push token is already in use"
    )
  end

  defp validate_timeout_within_interval(changeset) do
    timeout = get_field(changeset, :timeout_ms)
    interval = get_field(changeset, :interval_seconds)

    if is_integer(timeout) and is_integer(interval) and timeout > interval * 1000 do
      add_error(changeset, :timeout_ms, "must not be longer than the check interval")
    else
      changeset
    end
  end

  defp normalize_tags(nil), do: []

  defp normalize_tags(tags) do
    tags
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Settings are always (re)validated against the current type, even when no
  # settings params are given, so that e.g. creating an http monitor without
  # a URL or changing a monitor's type is caught.
  defp cast_settings(changeset) do
    case get_field(changeset, :type) do
      nil ->
        changeset

      type ->
        params = Map.update(changeset.params || %{}, "settings", %{}, &(&1 || %{}))

        %{changeset | params: params}
        |> cast_embed(:settings, required: true, with: &Settings.changeset(&1, &2, type))
    end
  end

  defp cast_secrets(changeset) do
    case get_field(changeset, :type) do
      nil ->
        changeset

      type ->
        params = secret_params(changeset.params["secrets"])
        old = changeset.data.secrets || %{}

        secrets =
          for key <- secret_fields(type),
              value = secret_param(params, key, old[key]),
              into: %{},
              do: {key, value}

        if secrets == old, do: changeset, else: put_change(changeset, :secrets, secrets)
    end
  end

  defp secret_params(%{} = params),
    do: Map.new(params, fn {key, value} -> {to_string(key), value} end)

  defp secret_params(_params), do: %{}

  defp secret_param(params, key, old) do
    value = params[key]

    cond do
      is_binary(value) and value != "" -> value
      params["clear_" <> key] in [true, "true"] -> nil
      true -> old
    end
  end
end
