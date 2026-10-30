defmodule Sentinelix.EncryptedMap do
  @moduledoc """
  An Ecto type for maps that are stored encrypted (as a binary column).

  Used for values that contain secrets: notification channel configs (bot
  tokens, webhook URLs with embedded tokens, passwords in headers) and
  monitor secrets (e.g. database passwords). They are JSON encoded and
  encrypted with `Plug.Crypto.MessageEncryptor` (AES-256-GCM) using keys
  derived from the endpoint's `secret_key_base` (`SECRET_KEY_BASE` in
  production), so a database dump alone doesn't leak them.

  Rotating `SECRET_KEY_BASE` makes existing values unreadable: they load as
  an empty map (and an error is logged), so the affected channels and
  monitors have to be configured again.
  """

  use Ecto.Type

  require Logger

  alias Plug.Crypto.{KeyGenerator, MessageEncryptor}

  # The salts predate the use for monitor secrets; changing them would make
  # existing values unreadable.
  @secret_salt "sentinelix notification config encryption"
  @sign_salt "sentinelix notification config signing"

  @impl true
  def type, do: :binary

  @impl true
  def cast(map) when is_map(map), do: {:ok, map}
  def cast(_other), do: :error

  @impl true
  def dump(map) when is_map(map), do: {:ok, encrypt(map)}
  def dump(_other), do: :error

  @impl true
  def load(binary) when is_binary(binary) do
    case decrypt(binary) do
      {:ok, map} ->
        {:ok, map}

      :error ->
        Logger.error("Could not decrypt an encrypted value (was SECRET_KEY_BASE changed?)")

        {:ok, %{}}
    end
  end

  def load(_other), do: :error

  @impl true
  def embed_as(_format), do: :dump

  @doc false
  def encrypt(map) do
    {secret, sign_secret} = keys()
    map |> Jason.encode!() |> MessageEncryptor.encrypt(secret, sign_secret)
  end

  @doc false
  def decrypt(binary) do
    {secret, sign_secret} = keys()

    with {:ok, json} <- MessageEncryptor.decrypt(binary, secret, sign_secret),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  defp keys do
    base =
      Application.get_env(:sentinelix, SentinelixWeb.Endpoint, [])[:secret_key_base] ||
        raise "SentinelixWeb.Endpoint :secret_key_base is not configured"

    {
      KeyGenerator.generate(base, @secret_salt, length: 32, cache: Plug.Crypto.Keys),
      KeyGenerator.generate(base, @sign_salt, cache: Plug.Crypto.Keys)
    }
  end
end
