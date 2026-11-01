defmodule Sentinelix.Monitoring.Settings.Assertion do
  @moduledoc """
  A response assertion of an HTTP monitor (`Sentinelix.Monitoring.Settings`
  field `assertions`), evaluated by `Sentinelix.Checks.HTTP` once the status
  code has been accepted. All assertions of a monitor must pass.

    * `source` – what is tested:
      * `"body"` – the whole response body (as text),
      * `"json"` – the value at the dot-path `path` of the JSON response
        body (see `Sentinelix.Monitoring.Settings.parse_json_path/1`),
      * `"header"` – the value of the response header `path` (repeated
        headers are joined with `", "`).
    * `comparison` – one of `Sentinelix.Checks.Comparison.comparisons/0`;
      `exists` and `not_exists` only for `json` and `header`.
    * `value` – the expected value or pattern; not used by `exists` and
      `not_exists`. Must be a number for `<`, `<=`, `>`, `>=` and a valid
      regular expression for `regex` and `not_regex`.
    * `case_sensitive` – `false` compares text case-insensitively.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.Checks.Comparison
  alias Sentinelix.Monitoring.Settings

  @sources ~w(body json header)
  @header_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

  @primary_key false
  embedded_schema do
    field :source, :string, default: "body"
    field :path, :string
    field :comparison, :string, default: "contains"
    field :value, :string
    field :case_sensitive, :boolean, default: true
  end

  @type t :: %__MODULE__{
          source: String.t(),
          path: String.t() | nil,
          comparison: String.t(),
          value: String.t() | nil,
          case_sensitive: boolean()
        }

  @doc "The sources an assertion can test."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "The comparisons allowed for a source."
  @spec comparisons(String.t() | nil) :: [String.t()]
  def comparisons("body"), do: Enum.reject(Comparison.comparisons(), &Comparison.presence?/1)
  def comparisons(_source), do: Comparison.comparisons()

  @doc "Whether the source has a `path` (JSON path or header name)."
  @spec path?(String.t() | nil) :: boolean()
  def path?(source), do: source in ["json", "header"]

  @doc "Whether the comparison uses a `value`."
  @spec value?(String.t() | nil) :: boolean()
  def value?(comparison), do: not Comparison.presence?(comparison)

  @doc "Whether the assertion needs the response body."
  @spec needs_body?(t()) :: boolean()
  def needs_body?(%__MODULE__{source: source}), do: source in ["body", "json"]

  @doc false
  def changeset(assertion, attrs) do
    assertion
    |> cast(attrs, [:source, :path, :comparison, :value, :case_sensitive])
    |> update_change(:path, &trim/1)
    |> validate_required([:source, :comparison])
    |> validate_inclusion(:source, @sources)
    |> validate_comparison()
    |> validate_path()
    |> validate_value()
  end

  defp trim(path) do
    case String.trim(path) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_comparison(changeset) do
    source = get_field(changeset, :source)

    validate_change(changeset, :comparison, fn field, comparison ->
      cond do
        comparison in comparisons(source) -> []
        comparison in Comparison.comparisons() -> [{field, "is not available for the body"}]
        true -> [{field, "is invalid"}]
      end
    end)
  end

  defp validate_path(changeset) do
    case get_field(changeset, :source) do
      "json" ->
        changeset
        |> validate_required([:path])
        |> validate_change(:path, &validate_json_path/2)

      "header" ->
        changeset
        |> validate_required([:path])
        |> validate_format(:path, @header_name, message: "must be a header name")

      _body ->
        put_change(changeset, :path, nil)
    end
  end

  defp validate_json_path(field, path) do
    case Settings.parse_json_path(path) do
      {:ok, _segments} -> []
      :error -> [{field, ~s(must be a dot-separated path like "data.items.0.status")}]
    end
  end

  defp validate_value(changeset) do
    comparison = get_field(changeset, :comparison)
    value = get_field(changeset, :value)

    cond do
      not value?(comparison) ->
        put_change(changeset, :value, nil)

      is_nil(value) ->
        add_error(changeset, :value, "can't be blank")

      Comparison.numeric?(comparison) and Comparison.parse_number(value) == :error ->
        add_error(changeset, :value, "must be a number for #{comparison}")

      Comparison.regex?(comparison) and not Comparison.valid_regex?(value) ->
        add_error(changeset, :value, "must be a valid regular expression")

      true ->
        changeset
    end
  end

  @doc """
  The assertion as a list of `{key, value}` pairs (for the export), without
  the fields that don't apply and with `case_sensitive` only when `false`.
  """
  @spec to_pairs(t()) :: [{String.t(), String.t() | boolean()}]
  def to_pairs(%__MODULE__{} = assertion) do
    [
      {"source", assertion.source},
      {"path", if(path?(assertion.source), do: assertion.path)},
      {"comparison", assertion.comparison},
      {"value", if(value?(assertion.comparison), do: assertion.value)},
      {"case_sensitive", if(assertion.case_sensitive == false, do: false)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
