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
  """

  use Ecto.Schema
  import Ecto.Changeset

  @http_methods ~w(GET HEAD POST PUT PATCH DELETE OPTIONS)
  @dns_record_types ~w(A AAAA CNAME MX TXT NS)
  @max_redirects_limit 20

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
    keyword: @http_fields ++ [keyword: nil, invert_keyword: false, case_sensitive: true],
    tcp: [host: nil, port: nil],
    ping: [host: nil],
    dns: [host: nil, dns_record_type: "A", dns_resolver: nil, expected_value: nil],
    cert: [host: nil, port: 443, cert_warn_days: 30, cert_critical_days: 7],
    push: [push_token: nil]
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

    # tcp / ping / dns / cert
    field :host, :string
    field :port, :integer

    # dns
    field :dns_record_type, :string
    field :dns_resolver, :string
    field :expected_value, :string

    # cert
    field :cert_warn_days, :integer
    field :cert_critical_days, :integer

    # push
    field :push_token, :string
  end

  @type t :: %__MODULE__{}

  @doc "Allowed HTTP methods."
  def http_methods, do: @http_methods

  @doc "Allowed DNS record types."
  def dns_record_types, do: @dns_record_types

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
  @trimmed_fields [:url, :method, :host, :dns_record_type, :dns_resolver, :push_token]

  defp trim_strings(changeset) do
    @trimmed_fields
    |> Enum.reduce(changeset, fn field, acc ->
      update_change(acc, field, &(&1 && String.trim(&1)))
    end)
    |> update_change(:accepted_status_codes, fn
      nil -> nil
      codes -> codes |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end)
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
  end

  defp validate_type(changeset, _type), do: changeset

  defp validate_keyword(changeset, :keyword), do: validate_required(changeset, [:keyword])
  defp validate_keyword(changeset, _type), do: changeset

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
