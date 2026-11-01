defmodule Sentinelix.Monitoring.Settings do
  @moduledoc """
  Type-specific monitor settings, stored as JSON in `monitors.settings`.

  This is a single embedded schema holding the union of all type-specific
  fields. Which fields are relevant – and how they are validated and
  defaulted – depends on the monitor `type` and is described by
  `fields_for/1`. Fields that don't apply to the monitor's type are reset to
  `nil`, so switching a monitor's type doesn't leave stale settings behind.

  Being a regular embed means forms can use `inputs_for :settings` and
  validation errors are nested under `:settings` like any other embed.

  ## Adding a check type

    1. Add the type to `Sentinelix.Monitoring.Monitor.types/0`.
    2. Add any new fields to the embedded schema below.
    3. Add a `@type_fields` entry (field => default) and, if needed, a
       `validate_type/2` clause.
    4. Implement `Sentinelix.Checks.Check` and register it in
       `Sentinelix.Checks`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.Checks.Comparison
  alias Sentinelix.Checks.Postgres.{Expectation, Replication}

  @http_methods ~w(GET HEAD POST PUT PATCH DELETE OPTIONS)
  @dns_record_types ~w(A AAAA CNAME MX TXT NS)
  @max_redirects_limit 20
  @max_push_grace_seconds 86_400
  @ssl_modes ~w(disable require verify-full)
  @max_query_length 10_000

  @http_fields [
    url: nil,
    method: "GET",
    headers: %{},
    body: nil,
    accepted_status_codes: [],
    follow_redirects: true,
    max_redirects: 10,
    verify_tls: true
  ]

  # field => default value, per type. A `nil` default means "no default".
  @type_fields %{
    http: @http_fields,
    keyword:
      @http_fields ++
        [keyword: nil, invert_keyword: false, case_sensitive: true, json_path: nil],
    tcp: [host: nil, port: nil],
    ping: [host: nil],
    dns: [host: nil, dns_record_type: "A", dns_resolver: nil, expected_value: nil],
    cert: [host: nil, port: 443, cert_warn_days: 30, cert_critical_days: 7],
    push: [push_token: nil, push_grace_seconds: 30],
    postgres: [
      host: nil,
      port: 5432,
      database: nil,
      username: nil,
      ssl_mode: "require",
      ssl_ca_cert: nil,
      query: "SELECT 1",
      expected_value: nil,
      comparison: "equals",
      expected_rows: nil,
      rows_comparison: "equals",
      replication_check: "none",
      min_standbys: 1,
      lag_warn_seconds: nil,
      lag_critical_seconds: nil,
      lag_warn_bytes: nil,
      lag_critical_bytes: nil
    ]
  }

  @primary_key false
  embedded_schema do
    # http / keyword
    field :url, :string
    field :method, :string
    field :headers, {:map, :string}
    field :body, :string
    field :accepted_status_codes, {:array, :string}
    field :follow_redirects, :boolean
    field :max_redirects, :integer
    field :verify_tls, :boolean

    # keyword
    field :keyword, :string
    field :invert_keyword, :boolean
    field :case_sensitive, :boolean
    # Optional: compare the value at this dot-path of a JSON response body
    # with `keyword` instead of searching the body for it.
    field :json_path, :string

    # tcp / ping / dns / cert / postgres
    field :host, :string
    field :port, :integer

    # dns
    field :dns_record_type, :string
    field :dns_resolver, :string
    # dns / postgres
    field :expected_value, :string

    # cert
    field :cert_warn_days, :integer
    field :cert_critical_days, :integer

    # push
    field :push_token, :string
    # Extra time after the interval before a missing push counts as down.
    field :push_grace_seconds, :integer

    # postgres (the password is a secret, see Monitor.secret_fields/1)
    field :database, :string
    field :username, :string
    # "disable", "require" (encrypted, certificate not verified) or
    # "verify-full" (verified against `ssl_ca_cert` or the system CAs).
    field :ssl_mode, :string
    # PEM encoded CA certificate(s) for "verify-full".
    field :ssl_ca_cert, :string
    field :query, :string
    # Optional assertions on the query result, see
    # Sentinelix.Checks.Postgres.Expectation. (`expected_value` is shared
    # with dns.)
    field :comparison, :string
    field :expected_rows, :integer
    field :rows_comparison, :string
    # Replication status, see Sentinelix.Checks.Postgres.Replication:
    # "none", "primary" or "standby".
    field :replication_check, :string
    field :min_standbys, :integer
    field :lag_warn_seconds, :integer
    field :lag_critical_seconds, :integer
    field :lag_warn_bytes, :integer
    field :lag_critical_bytes, :integer
  end

  @type t :: %__MODULE__{}

  @doc "Allowed HTTP methods."
  def http_methods, do: @http_methods

  @doc "Allowed DNS record types."
  def dns_record_types, do: @dns_record_types

  @doc "Allowed PostgreSQL SSL modes."
  def ssl_modes, do: @ssl_modes

  @doc """
  The settings fields (in display order) relevant for a monitor type.
  """
  @spec fields_for(atom()) :: [atom()]
  def fields_for(type), do: type |> type_spec() |> Keyword.keys()

  @doc """
  Default values of the settings fields relevant for a monitor type.
  """
  @spec defaults_for(atom()) :: map()
  def defaults_for(type), do: type |> type_spec() |> Map.new()

  defp type_spec(type), do: Map.get(@type_fields, type, [])

  @doc """
  Builds a settings changeset for the given monitor `type`.
  """
  def changeset(settings, attrs, type) do
    fields = fields_for(type)
    irrelevant = __schema__(:fields) -- fields

    settings
    |> cast(attrs, fields)
    |> trim_strings()
    |> reset_fields(irrelevant)
    |> apply_defaults(type)
    |> validate_type(type)
  end

  # Identifier-like fields where surrounding whitespace is never intended.
  # (Free-text fields such as `body` and `keyword` are kept verbatim.)
  # Blank accepted status code entries (e.g. empty form inputs) are dropped.
  @trimmed_fields [
    :url,
    :method,
    :host,
    :dns_record_type,
    :dns_resolver,
    :json_path,
    :push_token,
    :database,
    :username,
    :ssl_mode,
    :ssl_ca_cert,
    :query
  ]

  defp trim_strings(changeset) do
    @trimmed_fields
    |> Enum.reduce(changeset, fn field, acc ->
      update_change(acc, field, &trim/1)
    end)
    |> update_change(:accepted_status_codes, fn
      nil -> nil
      codes -> codes |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end)
  end

  defp trim(nil), do: nil

  defp trim(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp reset_fields(changeset, fields) do
    Enum.reduce(fields, changeset, &put_change(&2, &1, nil))
  end

  defp apply_defaults(changeset, type) do
    Enum.reduce(type_spec(type), changeset, fn
      {_field, nil}, acc ->
        acc

      {field, default}, acc ->
        if is_nil(get_field(acc, field)), do: put_change(acc, field, default), else: acc
    end)
  end

  defp validate_type(changeset, type) when type in [:http, :keyword] do
    changeset
    |> validate_required([:url])
    |> validate_http_url(:url)
    |> update_change(:method, &String.upcase/1)
    |> validate_inclusion(:method, @http_methods)
    |> validate_number(:max_redirects,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_redirects_limit
    )
    |> validate_status_codes()
    |> validate_headers()
    |> validate_keyword(type)
  end

  defp validate_type(changeset, type) when type in [:tcp, :ping] do
    changeset
    |> validate_required(if type == :tcp, do: [:host, :port], else: [:host])
    |> validate_host(:host)
    |> validate_port()
  end

  defp validate_type(changeset, :dns) do
    changeset
    |> validate_required([:host, :dns_record_type])
    |> validate_host(:host)
    |> update_change(:dns_record_type, &String.upcase/1)
    |> validate_inclusion(:dns_record_type, @dns_record_types)
    |> validate_ip(:dns_resolver)
  end

  defp validate_type(changeset, :cert) do
    changeset
    |> validate_required([:host, :port, :cert_warn_days, :cert_critical_days])
    |> validate_host(:host)
    |> validate_port()
    |> validate_number(:cert_warn_days, greater_than: 0)
    |> validate_number(:cert_critical_days, greater_than: 0)
    |> validate_cert_days()
  end

  defp validate_type(changeset, :push) do
    changeset
    |> then(fn cs ->
      if get_field(cs, :push_token), do: cs, else: put_change(cs, :push_token, generate_token())
    end)
    |> validate_length(:push_token, min: 16, max: 128)
    |> validate_format(:push_token, ~r/\A[A-Za-z0-9_-]+\z/,
      message: "may only contain letters, digits, - and _"
    )
    |> validate_required([:push_grace_seconds])
    |> validate_number(:push_grace_seconds,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_push_grace_seconds
    )
  end

  defp validate_type(changeset, :postgres) do
    changeset
    |> validate_required([:host, :port, :database, :username, :ssl_mode, :query])
    |> validate_host(:host)
    |> validate_port()
    |> validate_length(:database, max: 63)
    |> validate_length(:username, max: 63)
    |> validate_inclusion(:ssl_mode, @ssl_modes)
    |> validate_change(:ssl_ca_cert, fn field, pem ->
      case parse_ca_certs(pem) do
        {:ok, _certs} -> []
        :error -> [{field, "must contain PEM encoded certificates"}]
      end
    end)
    |> validate_length(:query, max: @max_query_length)
    |> validate_inclusion(:comparison, Expectation.comparisons())
    |> validate_expected_value()
    |> validate_number(:expected_rows, greater_than_or_equal_to: 0)
    |> validate_inclusion(:rows_comparison, Expectation.rows_comparisons())
    |> validate_required([:replication_check, :min_standbys])
    |> validate_inclusion(:replication_check, Replication.modes())
    |> validate_number(:min_standbys, greater_than_or_equal_to: 0)
    |> validate_thresholds(:lag_warn_seconds, :lag_critical_seconds)
    |> validate_thresholds(:lag_warn_bytes, :lag_critical_bytes)
  end

  defp validate_type(changeset, _type), do: changeset

  defp validate_keyword(changeset, :keyword) do
    changeset
    |> validate_required([:keyword])
    |> validate_change(:json_path, fn field, path ->
      case parse_json_path(path) do
        {:ok, _segments} -> []
        :error -> [{field, ~s(must be a dot-separated path like "data.items.0.status")}]
      end
    end)
  end

  defp validate_keyword(changeset, _type), do: changeset

  # Validated whenever the comparison or the value changes.
  defp validate_expected_value(changeset) do
    comparison = get_field(changeset, :comparison)
    value = get_field(changeset, :expected_value)

    cond do
      is_nil(value) ->
        changeset

      Comparison.numeric?(comparison) and Comparison.parse_number(value) == :error ->
        add_error(changeset, :expected_value, "must be a number for #{comparison}")

      comparison == "regex" and not Comparison.valid_regex?(value) ->
        add_error(changeset, :expected_value, "must be a valid regular expression")

      true ->
        changeset
    end
  end

  defp validate_thresholds(changeset, warn_field, critical_field) do
    changeset =
      changeset
      |> validate_number(warn_field, greater_than: 0)
      |> validate_number(critical_field, greater_than: 0)

    warn = get_field(changeset, warn_field)
    critical = get_field(changeset, critical_field)

    if is_integer(warn) and is_integer(critical) and critical < warn do
      add_error(changeset, critical_field, "must not be less than the warning threshold")
    else
      changeset
    end
  end

  defp validate_port(changeset) do
    validate_number(changeset, :port, greater_than: 0, less_than_or_equal_to: 65_535)
  end

  defp validate_cert_days(changeset) do
    warn = get_field(changeset, :cert_warn_days)
    critical = get_field(changeset, :cert_critical_days)

    if is_integer(warn) and is_integer(critical) and critical > warn do
      add_error(changeset, :cert_critical_days, "must not be greater than the warning days")
    else
      changeset
    end
  end

  @doc false
  def validate_http_url(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      case URI.new(value) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be a valid http:// or https:// URL"}]
      end
    end)
  end

  # Hostnames (letters, digits, '-', '_' and dots, labels not starting with
  # '-') or IP addresses. Leading dashes are rejected so a host can never be
  # mistaken for a command line option (e.g. by `ping`).
  @hostname ~r/\A(?=.{1,253}\.?\z)[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?(?:\.[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?)*\.?\z/

  defp validate_host(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      if ip?(value) or Regex.match?(@hostname, value),
        do: [],
        else: [{field, "must be a valid hostname or IP address"}]
    end)
  end

  defp validate_ip(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      if ip?(value), do: [], else: [{field, "must be a valid IP address"}]
    end)
  end

  defp ip?(value), do: match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(value)))

  @status_code_pattern ~r/\A([1-5]\d\d)(?:-([1-5]\d\d))?\z/

  defp validate_status_codes(changeset) do
    validate_change(changeset, :accepted_status_codes, fn field, codes ->
      if Enum.all?(codes, &valid_status_code_spec?/1),
        do: [],
        else: [{field, ~s(must be status codes or ranges like "200" or "200-299")}]
    end)
  end

  defp valid_status_code_spec?(spec) do
    case Regex.run(@status_code_pattern, spec) do
      [_, _code] -> true
      [_, from, to] -> String.to_integer(from) <= String.to_integer(to)
      nil -> false
    end
  end

  @header_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

  defp validate_headers(changeset) do
    validate_change(changeset, :headers, fn field, headers ->
      valid? =
        Enum.all?(headers, fn {name, value} ->
          Regex.match?(@header_name, name) and not String.contains?(value, ["\r", "\n"])
        end)

      if valid?, do: [], else: [{field, "contains an invalid header name or value"}]
    end)
  end

  @doc """
  Parses a JSON dot-path (e.g. `"data.items.0.status"`, optionally prefixed
  with `$.`) into its segments. Segments must not be empty; numeric segments
  also index into arrays.

      iex> parse_json_path("$.data.items.0")
      {:ok, ["data", "items", "0"]}
  """
  @spec parse_json_path(String.t()) :: {:ok, [String.t()]} | :error
  def parse_json_path(path) when is_binary(path) do
    segments = path |> String.replace_prefix("$.", "") |> String.split(".")

    if path != "" and Enum.all?(segments, &(&1 != "")),
      do: {:ok, segments},
      else: :error
  end

  @doc """
  Parses PEM encoded certificates into a list of DER binaries.
  """
  @spec parse_ca_certs(String.t()) :: {:ok, [binary()]} | :error
  def parse_ca_certs(pem) when is_binary(pem) do
    case for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der) do
      [] -> :error
      ders -> {:ok, ders}
    end
  rescue
    _ -> :error
  end

  @doc """
  Generates a random, URL-safe push token.
  """
  def generate_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc """
  Returns the accepted HTTP status codes as a list of ranges.

  An empty `accepted_status_codes` list means the default: `200..399` when
  redirects are followed, `200..299` otherwise.

      iex> accepted_status_ranges(%Settings{accepted_status_codes: ["200", "300-399"]})
      [200..200, 300..399]
  """
  @spec accepted_status_ranges(t()) :: [Range.t()]
  def accepted_status_ranges(%__MODULE__{accepted_status_codes: codes} = settings)
      when codes in [nil, []] do
    if settings.follow_redirects == false, do: [200..299], else: [200..399]
  end

  def accepted_status_ranges(%__MODULE__{accepted_status_codes: codes}) do
    Enum.map(codes, fn spec ->
      case String.split(spec, "-") do
        [code] -> String.to_integer(code)..String.to_integer(code)
        [from, to] -> String.to_integer(from)..String.to_integer(to)
      end
    end)
  end

  @doc """
  Whether `status_code` is accepted by the settings' `accepted_status_codes`.
  """
  @spec accepted_status?(t(), integer()) :: boolean()
  def accepted_status?(settings, status_code) do
    settings |> accepted_status_ranges() |> Enum.any?(&(status_code in &1))
  end
end
