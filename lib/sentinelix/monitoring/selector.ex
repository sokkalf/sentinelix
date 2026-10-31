defmodule Sentinelix.Monitoring.Selector do
  @max_length 2000

  @moduledoc ~S"""
  Label selectors: a small language that selects monitors by their labels
  (user and automatic, see `Sentinelix.Monitoring.Labels` and
  `Sentinelix.Monitoring.AutoLabels`), their name and their status.

      env=prod, site in (oslo,helsinki), service!=legacy, !deprecated, host

  The same selectors filter the dashboard and the monitor list, and are
  stored by the features that pick monitors dynamically (saved views,
  maintenance windows, notification routing, status page groups).

  ## Grammar

      selector  = [ term { "," term } ]          (empty: matches every monitor)
      term      = key                            the label key is present
                | "!" key                        the label key is absent
                | key ( "=" | "==" ) value       the label has exactly this value
                | key "!=" value                 the label is absent or has another value
                | key "~" value                  the value contains the text (case-insensitive)
                | key "!~" value                 the label is absent or doesn't contain it
                | key "in" "(" values ")"        the label has one of the values
                | key "notin" "(" values ")"     the label is absent or has none of them
      values    = value { "," value }
      key       = [A-Za-z0-9] [A-Za-z0-9_./-]*   (lowercased)
      value     = bare | quoted
      bare      = one or more characters except whitespace and , ( ) " = ! ~
      quoted    = '"' { any character, with \" for " and \\ for \ } '"'

  Terms are separated by commas and all have to match (AND). Whitespace
  between tokens is ignored; `in` and `notin` follow the key after a space.
  Label keys and values never need quotes (they contain none of the special
  characters); quotes are for names (`name~"web 1"`). Values are compared
  exactly and are case-sensitive, except for `~` and `!~`. Empty values are
  not allowed: write `key` to select a key with any value.

  A `!=`, `!~` or `notin` term also matches monitors without the key, as in
  Kubernetes label selectors.

  ## Pseudo-labels

  Two keys don't select labels but other properties of a monitor (so
  labels named `status` or `name` can't be selected):

    * `status` – the monitor's current status as shown on the dashboard
      (see `statuses/0`), with `=`, `!=`, `in` and `notin`:
      `status=down`, `status in (down,pending)`.
    * `name` – the monitor's name, with any operator that takes a value:
      `name~api` (contains, case-insensitive), `name="Web 1"` (exact).

  Neither can be used as `key` or `!key`: every monitor has both.

  ## Evaluation

  A selector is evaluated in memory with `matches?/3` or in the database
  with `filter/2` (or `to_dynamic/1`), on the union of user and automatic
  labels (`all_labels`). Both give the same answer for label and name terms.

  The **status is runtime state**, known to the processes and LiveViews that
  track monitors, not a column. Only the in-memory evaluator supports it, and
  the caller passes the status (`matches?(selector, monitor, status: :down)`);
  `filter/2` raises for selectors with `status` terms. Use
  `uses?(selector, :status)` to tell, `split_status/1` to query the rest in
  the database and check the status in memory, and `allow:` (see
  `parse/2`) where a status makes no sense, e.g. for maintenance windows:
  a window chosen by status would change its own monitors' status.

  ## Storing selectors

  Store a selector as its string (`to_string/1` is the normalized form) and
  validate the field with `validate_selector/3`. Stored selectors stay valid
  when label keys disappear: they just match nothing (or everything, for
  `!key`).
  """

  import Kernel, except: [to_string: 1]
  import Ecto.Query, only: [dynamic: 1, dynamic: 2, where: 2]

  alias Sentinelix.Monitoring.{CheckResult, Labels}

  defmodule Term do
    @moduledoc """
    A term of a selector: a `key` (a label key, or the pseudo-labels
    `"status"` and `"name"`), an operator and its values (none for
    `:exists` and `:absent`, one for `:eq`, `:neq`, `:contains` and
    `:not_contains`, one or more for `:in` and `:notin`).
    """

    @enforce_keys [:key, :op]
    defstruct [:key, :op, values: []]

    @type op :: :exists | :absent | :eq | :neq | :contains | :not_contains | :in | :notin
    @type t :: %__MODULE__{key: String.t(), op: op(), values: [String.t()]}
  end

  defmodule Error do
    @moduledoc """
    A selector that can't be parsed or isn't allowed. `position` is the
    0-based character offset the problem was found at (`nil` when it isn't
    about a position); the message names it as a 1-based column.
    """

    defexception [:reason, :position]

    @type t :: %__MODULE__{reason: String.t(), position: non_neg_integer() | nil}

    @impl true
    def message(%__MODULE__{reason: reason, position: nil}), do: reason

    def message(%__MODULE__{reason: reason, position: position}),
      do: "#{reason} at column #{position + 1}"
  end

  alias __MODULE__.{Error, Term}

  defstruct terms: []

  @type t :: %__MODULE__{terms: [Term.t()]}
  @type kind :: :labels | :name | :status

  @kinds [:labels, :name, :status]
  @pseudo_keys ["status", "name"]
  @statuses Enum.map(CheckResult.statuses(), &Atom.to_string/1) ++ ["paused"]

  @status_ops [:eq, :neq, :in, :notin]
  @value_ops [:eq, :neq, :contains, :not_contains]
  @op_text %{eq: "=", neq: "!=", contains: "~", not_contains: "!~"}

  @doc """
  The statuses `status` selects: those of check results plus `paused`
  (a disabled monitor), as the dashboard shows them.
  """
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The keys of pseudo-labels: `status` and `name`."
  @spec pseudo_keys() :: [String.t()]
  def pseudo_keys, do: @pseudo_keys

  ## Parsing

  @doc """
  Parses a selector.

  ## Options

    * `:allow` – the kinds of terms allowed, a list of `:labels`, `:name`
      and `:status` (default: all). A term of another kind is an error, e.g.
      `allow: [:labels, :name]` refuses `status=down`.

  ## Examples

      iex> {:ok, selector} = Sentinelix.Monitoring.Selector.parse("Env=prod, !legacy")
      iex> to_string(selector)
      "env=prod, !legacy"

      iex> {:error, error} = Sentinelix.Monitoring.Selector.parse("env=prod,")
      iex> Exception.message(error)
      "expected a label key at column 10"

      iex> {:error, error} = Sentinelix.Monitoring.Selector.parse("status=down", allow: [:labels])
      iex> Exception.message(error)
      "status can't be used here at column 1"
  """
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def parse(input, opts \\ [])

  def parse(input, opts) when is_binary(input) do
    allow = allowed_kinds(opts)

    with {:ok, chars} <- to_chars(input),
         {:ok, terms} <- parse_selector(chars, 0),
         :ok <- check_allowed(terms, allow) do
      {:ok, %__MODULE__{terms: terms |> Enum.map(&elem(&1, 0)) |> Enum.uniq()}}
    end
  end

  @doc """
  Like `parse/2`, but raises `Sentinelix.Monitoring.Selector.Error`.
  """
  @spec parse!(String.t(), keyword()) :: t()
  def parse!(input, opts \\ []) do
    case parse(input, opts) do
      {:ok, selector} -> selector
      {:error, error} -> raise error
    end
  end

  @doc """
  Validates a selector, given as a string (parsed with `parse/2`) or a
  struct, against the `:allow` option of `parse/2`.
  """
  @spec validate(t() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def validate(selector, opts \\ [])
  def validate(selector, opts) when is_binary(selector), do: parse(selector, opts)

  def validate(%__MODULE__{terms: terms} = selector, opts) do
    with :ok <- check_allowed(Enum.map(terms, &{&1, nil}), allowed_kinds(opts)),
         do: {:ok, selector}
  end

  @doc """
  Validates a selector stored as a string in a changeset `field`: a blank
  value becomes `""` (no selector; use `validate_required/2` to require
  one), a valid one is normalized (`to_string/1`), and an invalid one adds
  an error naming the problem and its column. Takes the options of
  `parse/2`.
  """
  @spec validate_selector(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def validate_selector(changeset, field, opts \\ []) do
    case Ecto.Changeset.get_change(changeset, field) do
      text when is_binary(text) ->
        case parse(text, opts) do
          {:ok, selector} -> Ecto.Changeset.put_change(changeset, field, to_string(selector))
          {:error, error} -> Ecto.Changeset.add_error(changeset, field, Exception.message(error))
        end

      _no_change ->
        changeset
    end
  end

  defp allowed_kinds(opts) do
    allow = Keyword.get(opts, :allow, @kinds)

    case allow -- @kinds do
      [] -> allow
      unknown -> raise ArgumentError, "unknown selector term kinds: #{inspect(unknown)}"
    end
  end

  defp to_chars(input) do
    case :unicode.characters_to_list(input) do
      chars when is_list(chars) and length(chars) > @max_length ->
        {:error, %Error{reason: "selector is too long (at most #{@max_length} characters)"}}

      chars when is_list(chars) ->
        {:ok, chars}

      _invalid ->
        {:error, %Error{reason: "selector is not valid text"}}
    end
  end

  defp check_allowed(terms, allow) do
    Enum.find_value(terms, :ok, fn {term, position} ->
      if kind(term) not in allow,
        do: {:error, %Error{reason: "#{term.key} can't be used here", position: position}}
    end)
  end

  defp kind(%Term{key: "status"}), do: :status
  defp kind(%Term{key: "name"}), do: :name
  defp kind(%Term{}), do: :labels

  # The parser works on a list of characters (code points), tracking the
  # position for error messages. Each step returns {:ok, result, rest,
  # position} or {:error, %Error{}}.

  defp parse_selector(chars, pos) do
    case skip_ws(chars, pos) do
      {[], _pos} -> {:ok, []}
      {chars, pos} -> parse_terms(chars, pos, [])
    end
  end

  defp parse_terms(chars, pos, acc) do
    with {:ok, term, rest, pos} <- parse_term(chars, pos) do
      case skip_ws(rest, pos) do
        {[], _pos} ->
          {:ok, Enum.reverse([term | acc])}

        {[?, | rest], pos} ->
          {rest, pos} = skip_ws(rest, pos + 1)
          parse_terms(rest, pos, [term | acc])

        {_other, pos} ->
          error(~s(expected "," or the end of the selector), pos)
      end
    end
  end

  defp parse_term([?! | rest], start) do
    {rest, pos} = skip_ws(rest, start + 1)

    with {:ok, key, rest, pos} <- parse_key(rest, pos),
         {:ok, term} <- build_term(key, :absent, [], start) do
      {:ok, {term, start}, rest, pos}
    end
  end

  defp parse_term(chars, start) do
    with {:ok, key, after_key, key_end} <- parse_key(chars, start) do
      {rest, pos} = skip_ws(after_key, key_end)

      case operator(rest) do
        {op, length} when op in @value_ops ->
          parse_operand(key, op, &parse_value/2, Enum.drop(rest, length), pos + length, start)

        {op, length} when op in [:in, :notin] and pos > key_end ->
          parse_operand(key, op, &parse_list/2, Enum.drop(rest, length), pos + length, start)

        _none ->
          parse_operand(key, :exists, &{:ok, [], &1, &2}, after_key, key_end, start)
      end
    end
  end

  defp parse_operand(key, op, parser, chars, pos, start) do
    with {:ok, operand, rest, pos} <- parser.(chars, pos),
         {:ok, term} <- build_term(key, op, List.wrap(operand), start) do
      {:ok, {term, start}, rest, pos}
    end
  end

  defp operator([?=, ?= | _rest]), do: {:eq, 2}
  defp operator([?= | _rest]), do: {:eq, 1}
  defp operator([?!, ?= | _rest]), do: {:neq, 2}
  defp operator([?!, ?~ | _rest]), do: {:not_contains, 2}
  defp operator([?~ | _rest]), do: {:contains, 1}
  defp operator([?i, ?n | rest]), do: keyword(:in, 2, rest)
  defp operator([?n, ?o, ?t, ?i, ?n | rest]), do: keyword(:notin, 5, rest)
  defp operator(_chars), do: nil

  # `in` / `notin` only when not the start of a longer word.
  defp keyword(op, length, [char | _rest]) when char in [?(, ?\s, ?\t, ?\n, ?\r],
    do: {op, length}

  defp keyword(op, length, []), do: {op, length}
  defp keyword(_op, _length, _rest), do: nil

  defp parse_key([char | _rest] = chars, pos)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 do
    {raw, rest} = Enum.split_while(chars, &key_char?/1)
    key = raw |> List.to_string() |> String.downcase()

    if Labels.valid_key?(key),
      do: {:ok, key, rest, pos + length(raw)},
      else: error("label key is too long", pos)
  end

  defp parse_key(_chars, pos), do: error("expected a label key", pos)

  defp key_char?(char),
    do: char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?., ?/, ?-]

  defp parse_value(chars, pos) do
    {chars, pos} = skip_ws(chars, pos)

    case chars do
      [?" | rest] ->
        parse_quoted(rest, pos + 1, pos, [])

      chars ->
        case Enum.split_while(chars, &bare_char?/1) do
          {[], _rest} -> error("expected a value", pos)
          {value, rest} -> {:ok, {List.to_string(value), pos}, rest, pos + length(value)}
        end
    end
  end

  defp parse_quoted([], _pos, start, _acc), do: error("unterminated quoted value", start)

  defp parse_quoted([?" | _rest], _pos, start, []), do: error("expected a value", start)

  defp parse_quoted([?" | rest], pos, start, acc),
    do: {:ok, {acc |> Enum.reverse() |> List.to_string(), start}, rest, pos + 1}

  defp parse_quoted([?\\, char | rest], pos, start, acc) when char in [?", ?\\],
    do: parse_quoted(rest, pos + 2, start, [char | acc])

  defp parse_quoted([char | rest], pos, start, acc),
    do: parse_quoted(rest, pos + 1, start, [char | acc])

  defp bare_char?(char),
    do: char not in [?,, ?(, ?), ?", ?=, ?!, ?~] and not whitespace?(char)

  defp whitespace?(char), do: char in [?\s, ?\t, ?\n, ?\r] or char in [0x85, 0xA0, 0x3000]

  defp parse_list(chars, pos) do
    case skip_ws(chars, pos) do
      {[?( | rest], pos} -> parse_list_values(rest, pos + 1, [])
      {_other, pos} -> error(~s{expected "("}, pos)
    end
  end

  defp parse_list_values(chars, pos, acc) do
    with {:ok, value, rest, pos} <- parse_value(chars, pos) do
      case skip_ws(rest, pos) do
        {[?, | rest], pos} -> parse_list_values(rest, pos + 1, [value | acc])
        {[?) | rest], pos} -> {:ok, Enum.reverse([value | acc]), rest, pos + 1}
        {_other, pos} -> error(~s{expected "," or ")"}, pos)
      end
    end
  end

  defp skip_ws([char | rest], pos) do
    if whitespace?(char), do: skip_ws(rest, pos + 1), else: {[char | rest], pos}
  end

  defp skip_ws([], pos), do: {[], pos}

  # Checks the operator and values (`{value, position}`) for the key.
  defp build_term("status", op, values, start) do
    cond do
      op not in @status_ops ->
        error("status takes =, !=, in or notin", start)

      bad = Enum.find(values, fn {value, _pos} -> String.downcase(value) not in @statuses end) ->
        {value, pos} = bad

        error(
          "unknown status #{inspect(value)}, expected one of #{Enum.join(@statuses, ", ")}",
          pos
        )

      true ->
        values = values |> Enum.map(&String.downcase(elem(&1, 0))) |> Enum.uniq()
        {:ok, %Term{key: "status", op: op, values: values}}
    end
  end

  defp build_term("name", op, _values, start) when op in [:exists, :absent],
    do: error("name takes =, !=, ~, !~, in or notin", start)

  defp build_term("name", op, values, _start),
    do: {:ok, %Term{key: "name", op: op, values: values |> Enum.map(&elem(&1, 0)) |> Enum.uniq()}}

  defp build_term(key, op, values, _start) do
    case Enum.find(values, fn {value, _pos} -> not Labels.valid_value?(value) end) do
      nil ->
        {:ok, %Term{key: key, op: op, values: values |> Enum.map(&elem(&1, 0)) |> Enum.uniq()}}

      {value, pos} ->
        error("invalid label value #{inspect(value)}", pos)
    end
  end

  defp error(reason, position), do: {:error, %Error{reason: reason, position: position}}

  ## Formatting

  @doc """
  The selector in its normalized form: terms separated by `", "`, values
  quoted only where needed. `parse/2` reads it back to an equal selector.

      iex> selector = Sentinelix.Monitoring.Selector.parse!(~s{site in(oslo ,bergen),name ~ "web 1"})
      iex> Sentinelix.Monitoring.Selector.to_string(selector)
      ~s{site in (oslo, bergen), name~"web 1"}
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{terms: terms}), do: Enum.map_join(terms, ", ", &term_to_string/1)

  @doc "A single term in the form of `to_string/1`."
  @spec term_to_string(Term.t()) :: String.t()
  def term_to_string(%Term{key: key, op: :exists}), do: key
  def term_to_string(%Term{key: key, op: :absent}), do: "!" <> key

  def term_to_string(%Term{key: key, op: op, values: [value]}) when op in @value_ops,
    do: key <> @op_text[op] <> quote_value(value)

  def term_to_string(%Term{key: key, op: op, values: values}) when op in [:in, :notin],
    do: "#{key} #{op} (#{Enum.map_join(values, ", ", &quote_value/1)})"

  defp quote_value(value) do
    if value != "" and value |> String.to_charlist() |> Enum.all?(&bare_char?/1) do
      value
    else
      ~s(") <> String.replace(value, ["\\", ~s(")], &("\\" <> &1)) <> ~s(")
    end
  end

  ## Building

  @doc "Whether the selector has no terms (it matches every monitor)."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{terms: terms}), do: terms == []

  @doc """
  Whether the selector has terms of the given kind (`:labels`, `:name` or
  `:status`).
  """
  @spec uses?(t(), kind()) :: boolean()
  def uses?(%__MODULE__{terms: terms}, kind) when kind in @kinds,
    do: Enum.any?(terms, &(kind(&1) == kind))

  @doc """
  Splits a selector into the terms the database can evaluate (labels and
  name) and its `status` terms: `{rest, status}`. A monitor matches the
  selector when it matches both.
  """
  @spec split_status(t()) :: {t(), t()}
  def split_status(%__MODULE__{terms: terms}) do
    {status, rest} = Enum.split_with(terms, &(kind(&1) == :status))
    {%__MODULE__{terms: rest}, %__MODULE__{terms: status}}
  end

  @doc """
  The term that selects a label `{key, value}`: `key=value`, or just `key`
  for a label without a value (any value).
  """
  @spec label_term({Labels.key(), Labels.value()}) :: Term.t()
  def label_term({key, ""}), do: %Term{key: key, op: :exists}
  def label_term({key, value}), do: %Term{key: key, op: :eq, values: [value]}

  @doc "The term `status=<status>`."
  @spec status_term(atom() | String.t()) :: Term.t()
  def status_term(status), do: %Term{key: "status", op: :eq, values: [Kernel.to_string(status)]}

  @doc "The term `name~<text>`."
  @spec name_term(String.t()) :: Term.t()
  def name_term(text), do: %Term{key: "name", op: :contains, values: [text]}

  @doc "Adds a term at the end, unless the selector already has it."
  @spec add(t(), Term.t()) :: t()
  def add(%__MODULE__{terms: terms} = selector, %Term{} = term) do
    if term in terms, do: selector, else: %{selector | terms: terms ++ [term]}
  end

  @doc "Removes a term."
  @spec delete(t(), Term.t()) :: t()
  def delete(%__MODULE__{terms: terms} = selector, %Term{} = term),
    do: %{selector | terms: List.delete(terms, term)}

  @doc "Removes all terms on `key`."
  @spec delete_key(t(), String.t()) :: t()
  def delete_key(%__MODULE__{terms: terms} = selector, key),
    do: %{selector | terms: Enum.reject(terms, &(&1.key == key))}

  @doc "Whether the selector has the term."
  @spec member?(t(), Term.t()) :: boolean()
  def member?(%__MODULE__{terms: terms}, %Term{} = term), do: term in terms

  ## In-memory evaluation

  @doc """
  Whether a monitor matches the selector.

  Labels are read from `monitor.all_labels`; for a monitor that wasn't
  saved yet (`all_labels` is `nil`) from `labels` and `auto_labels`, as
  the database would combine them.

  ## Options

    * `:status` – the monitor's status (an atom or string, see
      `statuses/0`) or a function of the monitor returning it. Required
      when the selector has `status` terms: raises `ArgumentError` without.
  """
  @spec matches?(t(), map(), keyword()) :: boolean()
  def matches?(%__MODULE__{terms: terms}, monitor, opts \\ []) do
    labels = labels_of(monitor)
    Enum.all?(terms, &term_matches?(&1, monitor, labels, opts))
  end

  defp labels_of(%{all_labels: labels}) when is_map(labels), do: labels

  defp labels_of(monitor),
    do: Map.merge(Map.get(monitor, :labels) || %{}, Map.get(monitor, :auto_labels) || %{})

  defp term_matches?(%Term{key: "status"} = term, monitor, _labels, opts),
    do: value_matches?(term, status_of(monitor, opts))

  defp term_matches?(%Term{key: "name"} = term, monitor, _labels, _opts),
    do: value_matches?(term, monitor.name)

  defp term_matches?(%Term{key: key, op: :exists}, _monitor, labels, _opts),
    do: Map.has_key?(labels, key)

  defp term_matches?(%Term{key: key, op: :absent}, _monitor, labels, _opts),
    do: not Map.has_key?(labels, key)

  defp term_matches?(%Term{key: key} = term, _monitor, labels, _opts),
    do: value_matches?(term, Map.get(labels, key))

  # `actual` is nil for a missing label.
  defp value_matches?(%Term{op: :eq, values: [value]}, actual), do: actual == value
  defp value_matches?(%Term{op: :neq, values: [value]}, actual), do: actual != value
  defp value_matches?(%Term{op: :in, values: values}, actual), do: actual in values
  defp value_matches?(%Term{op: :notin, values: values}, actual), do: actual not in values
  defp value_matches?(%Term{op: :contains}, nil), do: false

  defp value_matches?(%Term{op: :contains, values: [text]}, actual),
    do: String.contains?(String.downcase(actual), String.downcase(text))

  defp value_matches?(%Term{op: :not_contains} = term, actual),
    do: not value_matches?(%{term | op: :contains}, actual)

  defp status_of(monitor, opts) do
    case Keyword.fetch(opts, :status) do
      {:ok, fun} when is_function(fun, 1) -> Kernel.to_string(fun.(monitor))
      {:ok, status} when is_atom(status) or is_binary(status) -> Kernel.to_string(status)
      :error -> raise ArgumentError, "the selector has status terms: pass the :status option"
    end
  end

  ## Database evaluation

  @doc """
  Filters a query of monitors (`Sentinelix.Monitoring.Monitor`, the first
  binding) by the selector, see `to_dynamic/1`.
  """
  @spec filter(Ecto.Queryable.t(), t()) :: Ecto.Query.t()
  def filter(queryable, %__MODULE__{} = selector),
    do: where(queryable, ^to_dynamic(selector))

  @doc """
  The selector as an `Ecto.Query.dynamic/2` condition on the first binding
  of a query, a monitor: its `all_labels` (with the GIN index's `@>` and `?`
  operators) and `name`.

  Raises `ArgumentError` for `status` terms, the status isn't stored; see
  "Evaluation" above.
  """
  @spec to_dynamic(t()) :: Ecto.Query.dynamic_expr()
  def to_dynamic(%__MODULE__{terms: terms}) do
    Enum.reduce(terms, dynamic(true), fn term, acc ->
      condition = term_dynamic(term)
      dynamic(^acc and ^condition)
    end)
  end

  defp term_dynamic(%Term{key: "status"}) do
    raise ArgumentError,
          "status terms can't be evaluated in the database, " <>
            "see Sentinelix.Monitoring.Selector.split_status/1"
  end

  defp term_dynamic(%Term{key: "name", op: op, values: values}) do
    case {op, values} do
      {:eq, [value]} -> dynamic([m], m.name == ^value)
      {:neq, [value]} -> dynamic([m], m.name != ^value)
      {:in, values} -> dynamic([m], m.name in ^values)
      {:notin, values} -> dynamic([m], m.name not in ^values)
      {:contains, [text]} -> dynamic([m], ilike(m.name, ^like_pattern(text)))
      {:not_contains, [text]} -> dynamic([m], not ilike(m.name, ^like_pattern(text)))
    end
  end

  defp term_dynamic(%Term{key: key, op: :exists}),
    do: dynamic([m], fragment("? \\? ?", m.all_labels, ^key))

  defp term_dynamic(%Term{key: key, op: :absent}),
    do: dynamic([m], not fragment("? \\? ?", m.all_labels, ^key))

  defp term_dynamic(%Term{key: key, op: :eq, values: [value]}), do: has_label(key, value)

  defp term_dynamic(%Term{key: key, op: :neq, values: [value]}) do
    condition = has_label(key, value)
    dynamic(not (^condition))
  end

  defp term_dynamic(%Term{key: key, op: :in, values: values}), do: has_any_label(key, values)

  defp term_dynamic(%Term{key: key, op: :notin, values: values}) do
    condition = has_any_label(key, values)
    dynamic(not (^condition))
  end

  defp term_dynamic(%Term{key: key, op: :contains, values: [text]}),
    do: label_contains(key, text)

  defp term_dynamic(%Term{key: key, op: :not_contains, values: [text]}) do
    condition = label_contains(key, text)
    dynamic(not (^condition))
  end

  defp has_label(key, value),
    do: dynamic([m], fragment("? @> ?", m.all_labels, ^%{key => value}))

  defp has_any_label(key, values) do
    values
    |> Enum.map(&has_label(key, &1))
    |> Enum.reduce(fn condition, acc -> dynamic(^acc or ^condition) end)
  end

  # Never NULL (a missing key doesn't contain anything), so `not` works.
  defp label_contains(key, text) do
    pattern = like_pattern(text)

    dynamic(
      [m],
      fragment("coalesce((? ->> ?) ILIKE ?, false)", m.all_labels, ^key, ^pattern)
    )
  end

  # A LIKE pattern matching values that contain `text` literally.
  defp like_pattern(text), do: "%" <> String.replace(text, ["\\", "%", "_"], &("\\" <> &1)) <> "%"

  defimpl String.Chars do
    alias Sentinelix.Monitoring.Selector

    def to_string(selector), do: Selector.to_string(selector)
  end
end
