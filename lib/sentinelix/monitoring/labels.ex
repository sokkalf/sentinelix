defmodule Sentinelix.Monitoring.Labels do
  @max_key_length 63
  @max_value_length 255
  @max_labels 64

  @moduledoc """
  Key/value labels on monitors (`env=prod`, `site=helsinki`, `host=db1`),
  to group and filter monitors along any dimension.

  ## Representation

  Labels are a map of key => value, both strings. A label without a value
  (e.g. a former tag) has the value `""` and is written as just its key.
  The map is stored as a `jsonb` object with a GIN index, so the database
  can answer the label queries selectors need with indexed operators:

    * `labels @> '{"env": "prod"}'` – has the label `env=prod`,
    * `labels ? 'env'` – has the key `env` (any value),

  and the same checks in memory are `Map.fetch(labels, "env") == {:ok,
  "prod"}` and `Map.has_key?(labels, "env")`.

  ## Rules

    * Keys are lowercased and consist of `a-z`, `0-9`, `_`, `.`, `-` and
      `/`, starting with a letter or digit, at most #{@max_key_length} characters.
    * Values keep their case and consist of letters, digits, `_`, `.`, `-`,
      `/`, `:` and `@`, at most #{@max_value_length} characters. They are compared
      exactly (case sensitive).
    * Keys and values are trimmed; a key appears at most once, and a
      monitor has at most #{@max_labels} labels.

  Neither contains whitespace, `,`, `=`, `!`, `~` or parentheses, so labels
  can be written in selectors without quoting.

  ## Casting

  As an `Ecto.Type`, labels cast from

    * a map of key => value (`nil` values become `""`), with string or atom
      keys,
    * a list of `"key=value"` / `"key"` strings, `{key, value}` tuples or
      `%{"key" => key, "value" => value}` rows (the monitor form); rows
      whose key and value are both blank are skipped.

  Invalid or duplicate keys and invalid values fail the cast with a message
  naming the label.
  """

  use Ecto.Type

  @key_format ~r/\A[a-z0-9][a-z0-9_.\/-]*\z/
  @value_format ~r/\A[A-Za-z0-9_.\/:@-]*\z/

  @type key :: String.t()
  @type value :: String.t()
  @type t :: %{optional(key()) => value()}

  @impl true
  def type, do: :map

  @impl true
  def cast(nil), do: {:ok, %{}}

  def cast(labels) when is_map(labels) and not is_struct(labels),
    do: labels |> Map.to_list() |> build()

  def cast(labels) when is_list(labels), do: build(labels)
  def cast(_labels), do: :error

  @impl true
  def load(labels) when is_map(labels), do: {:ok, labels}
  def load(_labels), do: :error

  @impl true
  def dump(labels) when is_map(labels), do: {:ok, labels}
  def dump(_labels), do: :error

  @impl true
  def embed_as(_format), do: :dump

  @doc """
  Parses a label written as `"key=value"` or `"key"` into a normalized
  `{key, value}`. The value of a bare key is `""`.

      iex> Sentinelix.Monitoring.Labels.parse(" Env = prod ")
      {:ok, {"env", "prod"}}

      iex> Sentinelix.Monitoring.Labels.parse("deprecated")
      {:ok, {"deprecated", ""}}
  """
  @spec parse(String.t()) :: {:ok, {key(), value()}} | {:error, String.t()}
  def parse(label) when is_binary(label) do
    case String.split(label, "=", parts: 2) do
      [key, value] -> normalize(key, value)
      [key] -> normalize(key, "")
    end
  end

  @doc """
  Normalizes (trims, lowercases the key) and validates a single label.
  """
  @spec normalize(term(), term()) :: {:ok, {key(), value()}} | {:error, String.t()}
  def normalize(key, value) do
    with {:ok, key} <- to_text(key),
         {:ok, value} <- to_text(value) do
      validate(key |> String.trim() |> String.downcase(), String.trim(value))
    else
      :error -> {:error, "invalid label #{inspect({key, value})}"}
    end
  end

  defp validate(key, value) do
    cond do
      key == "" -> {:error, "label #{inspect(value)} has no key"}
      not valid_key?(key) -> {:error, "invalid label key #{inspect(key)}"}
      not valid_value?(value) -> {:error, "invalid value #{inspect(value)} for label #{key}"}
      true -> {:ok, {key, value}}
    end
  end

  defp to_text(nil), do: {:ok, ""}
  defp to_text(text) when is_binary(text), do: {:ok, text}
  defp to_text(atom) when is_atom(atom), do: {:ok, Atom.to_string(atom)}
  defp to_text(number) when is_integer(number), do: {:ok, Integer.to_string(number)}
  defp to_text(_other), do: :error

  @doc "Whether `key` is a valid (normalized) label key."
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key),
    do: String.length(key) <= @max_key_length and Regex.match?(@key_format, key)

  def valid_key?(_key), do: false

  @doc "Whether `value` is a valid label value (`\"\"` is: a label without a value)."
  @spec valid_value?(term()) :: boolean()
  def valid_value?(value) when is_binary(value),
    do: String.length(value) <= @max_value_length and Regex.match?(@value_format, value)

  def valid_value?(_value), do: false

  @doc """
  The labels as `{key, value}` pairs, sorted by key.
  """
  @spec to_list(t() | nil) :: [{key(), value()}]
  def to_list(nil), do: []
  def to_list(labels), do: Enum.sort(labels)

  @doc """
  Formats a label as `"key=value"`, or `"key"` without a value. Given a map,
  formats all labels, sorted by key.

      iex> Sentinelix.Monitoring.Labels.format({"env", "prod"})
      "env=prod"

      iex> Sentinelix.Monitoring.Labels.format(%{"legacy" => "", "env" => "prod"})
      ["env=prod", "legacy"]
  """
  @spec format({key(), value()}) :: String.t()
  @spec format(t() | nil) :: [String.t()]
  def format({key, ""}), do: key
  def format({key, value}), do: key <> "=" <> value

  def format(labels) when is_map(labels) or is_nil(labels),
    do: labels |> to_list() |> Enum.map(&format/1)

  @doc """
  Whether `labels` has the label `{key, value}`. A label without a value
  (`{key, ""}`) matches any value of `key`, like a bare key in a selector.
  """
  @spec has?(t(), {key(), value()}) :: boolean()
  def has?(labels, {key, ""}), do: Map.has_key?(labels, key)
  def has?(labels, {key, value}), do: Map.fetch(labels, key) == {:ok, value}

  defp build(entries) do
    entries
    |> Enum.reject(&blank_row?/1)
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, acc} ->
      with {:ok, {key, value}} <- entry_label(entry),
           :ok <- unique(acc, key) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, message} -> {:halt, {:error, message: message}}
      end
    end)
    |> limit()
  end

  defp entry_label(label) when is_binary(label), do: parse(label)
  defp entry_label({key, value}), do: normalize(key, value)
  defp entry_label(%{"key" => key} = row), do: normalize(key, row["value"])
  defp entry_label(%{key: key} = row), do: normalize(key, row[:value])
  defp entry_label(other), do: {:error, "invalid label #{inspect(other)}"}

  defp blank_row?(%{} = row) when not is_struct(row) do
    blank?(row["key"] || row[:key]) and blank?(row["value"] || row[:value])
  end

  defp blank_row?(label) when is_binary(label), do: blank?(label)
  defp blank_row?(_entry), do: false

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_other), do: false

  defp unique(labels, key) do
    if Map.has_key?(labels, key), do: {:error, "duplicate label key #{key}"}, else: :ok
  end

  defp limit({:ok, labels}) when map_size(labels) > @max_labels,
    do: {:error, message: "at most #{@max_labels} labels are allowed"}

  defp limit(result), do: result
end
