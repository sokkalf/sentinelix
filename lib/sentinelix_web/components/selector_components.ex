defmodule SentinelixWeb.SelectorComponents do
  @moduledoc """
  The selector input (see `Sentinelix.Monitoring.Selector`) of the dashboard,
  the monitor list, status page groups and notification channels: a text
  field that shows parse errors inline and completes label keys and values.

  Completion needs no JavaScript: `suggestions/2` turns the text typed so
  far into whole selectors that complete its last term, which the input
  offers through a `<datalist>`.
  """

  use SentinelixWeb, :html

  alias Sentinelix.Monitoring.{Labels, Selector}

  @max_suggestions 50

  @doc """
  A selector input (named `selector` unless given a `name`), for a form
  with `phx-change`. Shows `error` (a `Sentinelix.Monitoring.Selector.Error`
  or a message) below the field.
  """
  attr :id, :string, required: true
  attr :name, :string, default: "selector"
  attr :value, :string, required: true
  attr :error, :any, default: nil
  attr :suggestions, :list, default: []
  attr :placeholder, :string, default: "env=prod, status=down, name~api"
  attr :class, :any, default: nil

  def selector_input(assigns) do
    ~H"""
    <div class={["w-full", @class]}>
      <label class={["input input-sm w-full", @error && "input-error"]}>
        <.icon name="hero-funnel" class="size-4 opacity-50" />
        <input
          type="search"
          id={@id}
          name={@name}
          value={@value}
          list={"#{@id}-suggestions"}
          placeholder={@placeholder}
          aria-label="Selector"
          aria-invalid={@error && "true"}
          aria-describedby={@error && "#{@id}-error"}
          phx-debounce="200"
          autocomplete="off"
          spellcheck="false"
          class="font-mono"
        />
      </label>
      <datalist id={"#{@id}-suggestions"}>
        <option :for={suggestion <- @suggestions} value={suggestion} />
      </datalist>
      <p :if={@error} id={"#{@id}-error"} class="mt-1 text-xs text-error" role="alert">
        {error_message(@error)}
      </p>
    </div>
    """
  end

  defp error_message(message) when is_binary(message), do: message
  defp error_message(error), do: Exception.message(error)

  @doc "The text of the `selector` URL parameter, `\"\"` without one."
  @spec selector_param(map()) :: String.t()
  def selector_param(%{"selector" => text}) when is_binary(text), do: text
  def selector_param(_params), do: ""

  @doc """
  The values to complete: label keys in use with their values (as
  `Sentinelix.Monitoring.list_label_values/1` returns them, `""` for labels
  without a value), plus the pseudo-labels `status` and `name`.
  """
  @spec completion_values(%{Labels.key() => [Labels.value()]}) :: %{String.t() => [String.t()]}
  def completion_values(label_values) do
    label_values
    |> Map.drop(Selector.pseudo_keys())
    |> Map.put("status", Selector.statuses())
    |> Map.put("name", [])
  end

  @doc """
  The label values of monitors (their `all_labels`), in the form of
  `Sentinelix.Monitoring.list_label_values/1`.
  """
  @spec label_values([map()]) :: %{Labels.key() => [Labels.value()]}
  def label_values(monitors) do
    monitors
    |> Enum.flat_map(&Map.to_list(&1.all_labels || %{}))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, values} -> {key, values |> Enum.uniq() |> Enum.sort()} end)
  end

  @doc """
  Completions of the selector `text` typed so far: whole selectors, `text`
  with its last term (or list value) completed from `values` (see
  `completion_values/1`).

      iex> values = %{"env" => ["dev", "prod"], "legacy" => [""]}
      iex> SentinelixWeb.SelectorComponents.suggestions("site=oslo, env=p", values)
      ["site=oslo, env=prod"]

      iex> values = %{"env" => ["dev", "prod"], "legacy" => [""]}
      iex> SentinelixWeb.SelectorComponents.suggestions("!le", values)
      ["!legacy"]
  """
  @spec suggestions(String.t(), %{String.t() => [String.t()]}) :: [String.t()]
  def suggestions(text, values) do
    {head, fragment, context} = split(text)

    completions =
      context
      |> complete(fragment, values)
      |> Enum.map(&(head <> &1))
      |> Enum.reject(&(&1 == text))

    case completions do
      [] -> next_terms(text, values)
      completions -> completions
    end
    |> Enum.take(@max_suggestions)
  end

  # Nothing left to complete in a valid selector: suggest the next term.
  defp next_terms(text, values) do
    trimmed = String.trim_trailing(text)

    case Selector.parse(trimmed) do
      {:ok, %Selector{terms: [_term | _rest]}} ->
        Enum.map(complete(:term, "", values), &(trimmed <> ", " <> &1))

      _empty_or_invalid ->
        []
    end
  end

  # Splits the text into what stays (`head`), the part being typed and
  # whether that's a term or a value in an `in (...)` list.
  defp split(text) do
    {term_start, list} = scan(String.graphemes(text), 0, 0, false, 0, nil)

    case list do
      nil ->
        {head, fragment} = split_at(text, term_start)
        {lead, fragment} = split_leading_ws(fragment)
        {head <> lead, fragment, :term}

      {list_start, value_start} ->
        {head, fragment} = split_at(text, value_start)
        {lead, fragment} = split_leading_ws(fragment)
        term = String.slice(text, term_start, list_start - term_start)
        {head <> lead, fragment, {:list, term}}
    end
  end

  # Finds where the last term starts and, inside an `in (...)` list, where
  # the list and its last value start.
  defp scan([], _pos, _depth, _quoted, term_start, list), do: {term_start, list}

  defp scan(["\\", _char | rest], pos, depth, true, term_start, list),
    do: scan(rest, pos + 2, depth, true, term_start, list)

  defp scan(["\"" | rest], pos, depth, quoted, term_start, list),
    do: scan(rest, pos + 1, depth, not quoted, term_start, list)

  defp scan([_char | rest], pos, depth, true, term_start, list),
    do: scan(rest, pos + 1, depth, true, term_start, list)

  defp scan(["(" | rest], pos, 0, false, term_start, _list),
    do: scan(rest, pos + 1, 1, false, term_start, {pos, pos + 1})

  defp scan([")" | rest], pos, 1, false, term_start, _list),
    do: scan(rest, pos + 1, 0, false, term_start, nil)

  defp scan(["," | rest], pos, 0, false, _term_start, list),
    do: scan(rest, pos + 1, 0, false, pos + 1, list)

  defp scan(["," | rest], pos, 1, false, term_start, {list_start, _value}),
    do: scan(rest, pos + 1, 1, false, term_start, {list_start, pos + 1})

  defp scan([_char | rest], pos, depth, false, term_start, list),
    do: scan(rest, pos + 1, depth, false, term_start, list)

  defp split_at(text, position),
    do: {String.slice(text, 0, position), String.slice(text, position..-1//1)}

  defp split_leading_ws(text) do
    trimmed = String.trim_leading(text)
    {String.slice(text, 0, String.length(text) - String.length(trimmed)), trimmed}
  end

  defp complete(:term, "!" <> prefix, values) do
    for {key, _values} <- sorted(values),
        key not in Selector.pseudo_keys(),
        String.starts_with?(key, String.downcase(String.trim_leading(prefix))),
        do: "!" <> key
  end

  defp complete(:term, fragment, values) do
    case Regex.run(~r/\A([A-Za-z0-9][A-Za-z0-9_.\/-]*)\s*(==|=|!=|!~|~)(.*)\z/u, fragment) do
      [_all, key, op, prefix] ->
        key = String.downcase(key)

        for value <- Map.get(values, key, []),
            value != "",
            String.starts_with?(value, String.trim_leading(prefix)),
            do: key <> op <> value

      nil ->
        prefix = String.downcase(fragment)

        for {key, key_values} <- sorted(values),
            String.starts_with?(key, prefix),
            suggestion <- key_suggestions(key, key_values),
            do: suggestion
    end
  end

  defp complete({:list, term}, fragment, values) do
    case Regex.run(~r/\A\s*([A-Za-z0-9][A-Za-z0-9_.\/-]*)\s+(?:in|notin)\s*\z/u, term) do
      [_all, key] ->
        for value <- Map.get(values, String.downcase(key), []),
            value != "",
            String.starts_with?(value, fragment),
            do: value

      nil ->
        []
    end
  end

  defp key_suggestions("name", _values), do: ["name~"]
  defp key_suggestions("status", values), do: Enum.map(values, &("status=" <> &1))

  defp key_suggestions(key, values),
    do: [key | for(value <- values, value != "", do: key <> "=" <> value)]

  defp sorted(values), do: Enum.sort(values)
end
