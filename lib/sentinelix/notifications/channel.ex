defmodule Sentinelix.Notifications.Channel do
  @moduledoc """
  A notification channel: a configured provider (email recipients, a Slack
  webhook, ...).

    * `config` – provider specific settings (string keys, see the
      provider's `fields/0`), encrypted at rest
      (`Sentinelix.Notifications.EncryptedMap`).
    * `enabled` – disabled channels are skipped when dispatching.
    * `default` – attached automatically to newly created monitors.

  Channels are attached to monitors through the
  `monitor_notification_channels` join table.

  ## Config params

  The changeset only keeps the provider's known fields, trims values and
  drops blank ones. A blank *secret* field keeps the stored value (the UI
  never renders secrets back), unless the channel's type changes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.Monitoring.Monitor
  alias Sentinelix.Notifications.{EncryptedMap, Provider}

  schema "notification_channels" do
    field :name, :string
    field :type, Ecto.Enum, values: Provider.types()
    field :config, EncryptedMap, default: %{}, skip_default_validation: true
    field :enabled, :boolean, default: true
    field :default, :boolean, default: false

    many_to_many :monitors, Monitor,
      join_through: "monitor_notification_channels",
      join_keys: [channel_id: :id, monitor_id: :id]

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :type, :enabled, :default])
    |> validate_required([:name, :type, :enabled, :default])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 255)
    |> put_config()
  end

  defp put_config(changeset) do
    case get_field(changeset, :type) do
      nil ->
        changeset

      type ->
        params = changeset.params["config"]
        type_changed? = changeset.data.type != type

        cond do
          is_map(params) -> cast_config(changeset, type, params, type_changed?)
          type_changed? -> cast_config(changeset, type, %{}, true)
          true -> changeset
        end
    end
  end

  defp cast_config(changeset, type, params, type_changed?) do
    provider = Provider.for_type(type)
    old = if type_changed?, do: %{}, else: changeset.data.config || %{}
    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)

    config =
      for field <- provider.fields(),
          value = normalize(params[field.key]) || (field[:secret] && old[field.key]),
          is_binary(value),
          into: %{},
          do: {field.key, value}

    changeset = put_change(changeset, :config, config)

    case provider.validate_config(config) do
      :ok ->
        changeset

      {:error, errors} ->
        Enum.reduce(errors, changeset, fn {key, message}, cs ->
          add_error(cs, :config, message, field: key)
        end)
    end
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil

  @doc """
  The config errors of a changeset for one config field.
  """
  @spec config_errors(Ecto.Changeset.t(), String.t()) :: [{String.t(), keyword()}]
  def config_errors(%Ecto.Changeset{errors: errors}, key) do
    for {:config, {message, opts}} <- errors, opts[:field] == key, do: {message, opts}
  end

  @doc """
  The non-secret config values, e.g. for a summary in a listing.
  """
  @spec public_config(t()) :: [{map(), String.t()}]
  def public_config(%__MODULE__{type: type, config: config}) do
    for field <- Provider.for_type(type).fields(),
        !field[:secret],
        value = config[field.key],
        value not in [nil, ""],
        do: {field, value}
  end
end
