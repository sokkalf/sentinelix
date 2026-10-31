defmodule Sentinelix.Monitoring.View do
  @moduledoc """
  A view of the monitors: which to show (a selector), how to group them
  and how to sort the groups. The state of the dashboard, kept in its URL
  so a view can be bookmarked and shared (and stored as a saved view).

  `from_params/1` reads a view from URL parameters and `to_params/1`
  writes it back, leaving out defaults, so `/` is the default view:

    * `selector` – a selector, see `Sentinelix.Monitoring.Selector`.
    * `group` – up to `max_group_by/0` label keys separated by commas,
      outermost first (`group=service,site`). Keys are lowercased; keys that
      aren't valid label keys, the pseudo-labels `status` and `name`, and
      repeated keys are ignored.
    * `sort` – the order of groups, `problems` (default) or `name`, see
      `Sentinelix.Monitoring.Grouping.sort_groups/2`.

  Parameters that aren't text are ignored. Links from before selectors
  still work: `q` (a name search) becomes a `name~` term, and `status`,
  `label` and `tag` (the filter labels replaced) become terms too.
  """

  alias Sentinelix.Monitoring.{Grouping, Labels, Selector}

  @max_group_by 2

  defstruct selector: %Selector{}, group_by: [], sort: :problems

  @typedoc """
  A view. `selector` is `nil` for a selector that doesn't parse, which
  shows no monitors.
  """
  @type t :: %__MODULE__{
          selector: Selector.t() | nil,
          group_by: [Labels.key()],
          sort: Grouping.sort()
        }

  @doc "The most label keys to group by (nesting levels)."
  @spec max_group_by() :: pos_integer()
  def max_group_by, do: @max_group_by

  @doc """
  Reads a view from URL parameters. A selector that doesn't parse gives
  `{:error, view, text, error}`, with the rest of the view and
  `selector: nil`.

      iex> {:ok, view} = Sentinelix.Monitoring.View.from_params(%{"group" => "Site, env", "sort" => "name"})
      iex> {view.group_by, view.sort}
      {["site", "env"], :name}
  """
  @spec from_params(map()) ::
          {:ok, t()} | {:error, t(), String.t(), Selector.Error.t()}
  def from_params(params) do
    view = %__MODULE__{
      group_by: group_by_param(params["group"]),
      sort: sort_param(params["sort"])
    }

    text = text_param(params["selector"])

    case Selector.parse(text) do
      {:ok, selector} ->
        {:ok,
         %{view | selector: Enum.reduce(legacy_terms(params), selector, &Selector.add(&2, &1))}}

      {:error, error} ->
        {:error, %{view | selector: nil}, text, error}
    end
  end

  @doc """
  The view as URL parameters, without defaults. An invalid selector is
  left out, and so is the sort when not grouping (it sorts groups).

      iex> view = %Sentinelix.Monitoring.View{group_by: ["site"]}
      iex> Sentinelix.Monitoring.View.to_params(view)
      [group: "site"]
  """
  @spec to_params(t()) :: keyword(String.t())
  def to_params(%__MODULE__{} = view) do
    [
      selector:
        view.selector && !Selector.empty?(view.selector) && Selector.to_string(view.selector),
      group: view.group_by != [] && Enum.join(view.group_by, ","),
      sort: (grouped?(view) and view.sort != :problems) && Atom.to_string(view.sort)
    ]
    |> Enum.filter(fn {_key, value} -> is_binary(value) end)
  end

  @doc "Whether the view groups monitors."
  @spec grouped?(t()) :: boolean()
  def grouped?(%__MODULE__{group_by: group_by}), do: group_by != []

  @doc """
  Parses group-by keys, given as a comma-separated string or a list, as
  `from_params/1` does: invalid, pseudo and repeated keys are dropped, at
  most `max_group_by/0` are kept.
  """
  @spec group_by_param(term()) :: [Labels.key()]
  def group_by_param(text) when is_binary(text), do: text |> String.split(",") |> group_by_param()

  def group_by_param(keys) when is_list(keys) do
    keys
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.filter(&(Labels.valid_key?(&1) and &1 not in Selector.pseudo_keys()))
    |> Enum.uniq()
    |> Enum.take(@max_group_by)
  end

  def group_by_param(_keys), do: []

  defp sort_param(text) do
    Enum.find(Grouping.sorts(), :problems, &(Atom.to_string(&1) == text))
  end

  defp text_param(text) when is_binary(text), do: text
  defp text_param(_text), do: ""

  defp legacy_terms(params) do
    search_term(params["q"]) ++
      status_term(params["status"]) ++ label_term(params["label"] || params["tag"])
  end

  defp search_term(text) when is_binary(text) do
    case String.trim(text) do
      "" -> []
      text -> [Selector.name_term(text)]
    end
  end

  defp search_term(_text), do: []

  defp status_term(status) when is_binary(status) do
    if status in Selector.statuses(), do: [Selector.status_term(status)], else: []
  end

  defp status_term(_status), do: []

  defp label_term(label) when is_binary(label) do
    case Labels.parse(label) do
      {:ok, label} -> [Selector.label_term(label)]
      {:error, _message} -> []
    end
  end

  defp label_term(_label), do: []
end
