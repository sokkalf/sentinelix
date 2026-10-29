defmodule Sentinelix.Notifications.Provider do
  @moduledoc """
  Behaviour of notification providers (email, Slack, ...).

  A provider describes its configuration with `fields/0`, validates a
  channel's config with `validate_config/1` and delivers an
  `Sentinelix.Notifications.Event` with `send/2`.

  Configs are maps with string keys (the field keys). Fields marked
  `secret: true` are never rendered back in the UI.

  `use Sentinelix.Notifications.Provider` declares the behaviour, gives a
  default `validate_config/1` based on `fields/0` (required fields, URLs
  and email addresses) and unimports `Kernel.send/2`.

  ## Adding a provider

  Implement the behaviour and add it to `@providers` below; the channel
  type enum, the validation and the settings page pick it up.
  """

  alias Sentinelix.Notifications.{Channel, Event}

  @type field :: %{
          required(:key) => String.t(),
          required(:label) => String.t(),
          required(:type) => :text | :url | :email | :password | :textarea | :select,
          optional(:required) => boolean(),
          optional(:secret) => boolean(),
          optional(:placeholder) => String.t(),
          optional(:help) => String.t(),
          optional(:default) => String.t(),
          optional(:options) => [String.t()]
        }

  @type errors :: [{String.t(), String.t()}]

  @doc "Human readable name of the provider."
  @callback label() :: String.t()

  @doc "The configuration fields."
  @callback fields() :: [field()]

  @doc "Validates a config; errors are `{field_key, message}` tuples."
  @callback validate_config(config :: map()) :: :ok | {:error, errors()}

  @doc "Sends an event to the channel."
  @callback send(Channel.t(), Event.t()) :: :ok | {:error, term()}

  @providers [
    email: Sentinelix.Notifications.Providers.Email,
    webhook: Sentinelix.Notifications.Providers.Webhook,
    slack: Sentinelix.Notifications.Providers.Slack,
    discord: Sentinelix.Notifications.Providers.Discord,
    telegram: Sentinelix.Notifications.Providers.Telegram,
    ntfy: Sentinelix.Notifications.Providers.Ntfy,
    gotify: Sentinelix.Notifications.Providers.Gotify
  ]

  @doc "All channel types."
  @spec types() :: [atom()]
  def types, do: Keyword.keys(@providers)

  @doc "The provider module for a channel type."
  @spec for_type(atom()) :: module()
  def for_type(type), do: Keyword.fetch!(@providers, type)

  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)
      import Kernel, except: [send: 2]

      @impl true
      def validate_config(config),
        do: unquote(__MODULE__).validate_fields(config, fields())

      defoverridable validate_config: 1
    end
  end

  @doc """
  Validates a config against field specs: required fields must be present,
  `:url` fields must be http(s) URLs and `:email` fields comma separated
  email addresses.
  """
  @spec validate_fields(map(), [field()]) :: :ok | {:error, errors()}
  def validate_fields(config, fields) do
    fields
    |> Enum.flat_map(fn field -> validate_field(field, blank_to_nil(config[field.key])) end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp validate_field(%{key: key} = field, nil),
    do: if(field[:required], do: [{key, "can't be blank"}], else: [])

  defp validate_field(%{key: key, type: :url}, value) do
    if valid_url?(value), do: [], else: [{key, "must be an http(s) URL"}]
  end

  defp validate_field(%{key: key, type: :email}, value) do
    if Enum.all?(split_list(value), &(&1 =~ ~r/^[^@\s,]+@[^@\s,]+$/)),
      do: [],
      else: [{key, "must be a comma separated list of email addresses"}]
  end

  defp validate_field(%{key: key, type: :select, options: options}, value) do
    if value in options, do: [], else: [{key, "is invalid"}]
  end

  defp validate_field(_field, _value), do: []

  @doc false
  def valid_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _ ->
        false
    end
  end

  def valid_url?(_value), do: false

  @doc false
  def split_list(value) when is_binary(value),
    do:
      value
      |> String.split([",", ";", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  def split_list(_value), do: []

  @doc false
  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  def blank_to_nil(value), do: value
end
