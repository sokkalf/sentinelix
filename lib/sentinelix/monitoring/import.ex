defmodule Sentinelix.Monitoring.Import do
  @moduledoc """
  Imports monitors from YAML in the format of `Sentinelix.Monitoring.Export`.

      mix sentinelix.import monitors.yaml --dry-run
      mix sentinelix.import monitors.yaml --report-missing
      bin/import_monitors monitors.yaml --dry-run    # in a release

  ## Matching

  Monitors are matched with the existing ones **by name** (exact, after
  trimming): a monitor in the file that has no namesake is created, one that
  has is updated, or left unchanged when it already matches the file.
  Names are what people see and what the file is reviewed by; a monitor
  renamed in the file is therefore created anew (the old one shows up as
  missing). A name that appears twice in the file, or that more than one
  existing monitor has, is an error.

  Each monitor in the file is a complete description: a field that is left
  out gets its default (the schema defaults for the schedule, no
  description, labels, parent or channels, the type's defaults for
  settings), so after an import a monitor is exactly what the file says,
  with two exceptions:

    * **Secrets** (e.g. the password of a PostgreSQL monitor) aren't part
      of the format: an updated monitor keeps its stored secrets and a
      created one has none, so set them in the UI after the import.
    * **Push tokens**: a `settings.push_token` in the file is used. Without
      one, an updated push monitor keeps its token and a created one gets a
      new token.

  `parent` names a monitor in the file or an existing one; `channels` name
  existing notification channels (exactly these are attached, the default
  channels aren't added). Monitors in the database that aren't in the file
  are left alone; with `missing: :report` they are listed.

  ## All or nothing

  The file is checked completely before anything is written: errors name
  the monitor and the field, and are all reported at once. The import then
  runs in one transaction (`Sentinelix.Monitoring.transaction/1`) through
  the context functions, so either every monitor is written or none is, and
  the workers of the changed monitors (re)start after the commit. Monitors
  are created and updated first and get their parents in a second pass
  (through `Sentinelix.Monitoring.update_monitor/2`, which rejects cycles),
  so a parent can come later in the file than its children.

  A dry run (`dry_run: true`) does the same checks and returns what would
  change, without writing.
  """

  import Ecto.Query, only: [from: 2]

  alias Sentinelix.{Monitoring, Notifications, Repo, YAML}
  alias Sentinelix.Monitoring.{Export, Monitor, Selector, Settings}
  alias Sentinelix.Notifications.Channel

  @max_bytes 5_000_000
  @max_monitors 10_000

  @top_keys ~w(version monitors)
  @monitor_keys ~w(name type enabled interval_seconds retry_interval_seconds max_retries
                   timeout_ms description parent labels channels settings)
  @schedule_fields [
    :enabled,
    :interval_seconds,
    :retry_interval_seconds,
    :max_retries,
    :timeout_ms
  ]

  defmodule Error do
    @moduledoc """
    A problem with an import file. `index` (0-based) and `name` say which
    monitor it is about and `field` which of its fields (`"settings.url"`);
    all three are `nil` for problems with the file as a whole.
    """

    defstruct [:index, :name, :field, :message]

    @type t :: %__MODULE__{
            index: non_neg_integer() | nil,
            name: String.t() | nil,
            field: String.t() | nil,
            message: String.t()
          }

    @doc """
    A one-line description, e.g. `monitor 3 "API": settings.url must be a
    valid http:// or https:// URL`.
    """
    @spec format(t()) :: String.t()
    def format(%__MODULE__{} = error) do
      [monitor(error), error.field && error.field <> " ", error.message]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()
    end

    defp monitor(%{index: nil}), do: nil
    defp monitor(%{index: index, name: nil}), do: "monitor #{index + 1}: "
    defp monitor(%{index: index, name: name}), do: "monitor #{index + 1} #{inspect(name)}: "
  end

  defmodule Change do
    @moduledoc """
    What an import does (or did) to one monitor of the file: `:create`,
    `:update` (`fields` lists what changes, e.g. `["interval_seconds",
    "settings.url", "parent", "channels"]`; values aren't shown, they may
    be credentials) or `:unchanged`. `monitor` is the existing monitor (the
    written one after an import), `nil` for a dry-run create.
    """

    defstruct [:action, :name, :monitor, fields: []]

    @type t :: %__MODULE__{
            action: :create | :update | :unchanged,
            name: String.t(),
            monitor: Sentinelix.Monitoring.Monitor.t() | nil,
            fields: [String.t()]
          }
  end

  defmodule Result do
    @moduledoc """
    The outcome of an import or dry run: a `Change` per monitor of the file
    (in file order) and, with `missing: :report`, the names of the existing
    monitors that aren't in the file (`nil` otherwise).
    """

    defstruct changes: [], missing: nil, dry_run: false

    @type t :: %__MODULE__{
            changes: [Sentinelix.Monitoring.Import.Change.t()],
            missing: [String.t()] | nil,
            dry_run: boolean()
          }

    @doc "The number of changes per action."
    @spec counts(t()) :: %{create: integer(), update: integer(), unchanged: integer()}
    def counts(%__MODULE__{changes: changes}) do
      Map.merge(
        %{create: 0, update: 0, unchanged: 0},
        Enum.frequencies_by(changes, & &1.action)
      )
    end
  end

  @typep entry :: %{
           index: non_neg_integer(),
           name: String.t(),
           attrs: map(),
           parent: String.t() | nil,
           channels: [String.t()] | nil,
           push_token?: boolean()
         }

  @doc """
  Imports the monitors of a YAML document.

  ## Options

    * `:dry_run` – only check the file and return what would change
      (default `false`).
    * `:missing` – `:ignore` (default) or `:report`: list the existing
      monitors that aren't in the file in `Result.missing`. They are never
      changed or deleted.
    * `:selector` – with `missing: :report`, only report monitors matching
      this selector (a struct or its text; label and name terms), e.g. the
      selector the file was exported with.

  Returns `{:error, errors}` with every problem found (nothing is written
  then).
  """
  @spec run(String.t(), keyword()) :: {:ok, Result.t()} | {:error, [Error.t()]}
  def run(yaml, opts \\ []) when is_binary(yaml) do
    with {:ok, selector} <- missing_selector(opts) do
      opts = Keyword.put(opts, :selector, selector)

      case parse(yaml) do
        {:ok, entries} -> run_entries(entries, opts)
        {:invalid, entries, names, errors} -> all_errors(entries, names, errors)
        {:error, errors} -> {:error, errors}
      end
    end
  end

  defp run_entries(entries, opts) do
    if Keyword.get(opts, :dry_run, false),
      do: dry_run(entries, opts),
      else: import_entries(entries, opts)
  end

  # Also checks the valid monitors of an invalid file, so every error is
  # reported at once.
  defp all_errors(entries, names, errors) do
    {_steps, step_errors} = steps(entries, names, Repo.all(Monitor))
    {:error, Enum.sort_by(errors ++ step_errors, & &1.index)}
  end

  defp missing_selector(opts) do
    case opts[:selector] do
      nil ->
        {:ok, %Selector{}}

      selector ->
        case Selector.validate(selector, allow: [:labels, :name]) do
          {:ok, selector} -> {:ok, selector}
          {:error, error} -> {:error, [file_error("selector: " <> Exception.message(error))]}
        end
    end
  end

  ## Parsing

  # The file's structure, before anything is looked up in the database.
  defp parse(yaml) do
    with :ok <- check_size(yaml),
         {:ok, document} <- decode(yaml),
         {:ok, monitors} <- document(document) do
      results =
        monitors
        |> Enum.with_index()
        |> Enum.map(fn {monitor, index} -> entry(monitor, index) end)
        |> check_duplicate_names()

      case collect(results) do
        {:ok, entries} -> {:ok, entries}
        {:error, errors} -> {:invalid, valid_entries(results), file_names(monitors), errors}
      end
    end
  end

  defp valid_entries(results), do: for({:ok, entry} <- results, do: entry)

  # The names in the file, also of monitors with errors (so that they are
  # still known as parents).
  defp file_names(monitors) do
    for %{"name" => name} <- monitors, is_binary(name), into: MapSet.new(), do: String.trim(name)
  end

  defp check_size(yaml) when byte_size(yaml) > @max_bytes,
    do: {:error, [file_error("the file is larger than #{div(@max_bytes, 1_000_000)} MB")]}

  defp check_size(_yaml), do: :ok

  defp decode(yaml) do
    case YAML.decode(yaml) do
      {:ok, document} -> {:ok, document}
      {:error, message} -> {:error, [file_error(message)]}
    end
  end

  defp document(%{} = document) do
    version = Export.version()
    monitors = document["monitors"] || []

    message =
      cond do
        Map.keys(document) -- @top_keys != [] ->
          "unknown key #{Enum.join(Map.keys(document) -- @top_keys, ", ")}"

        not Map.has_key?(document, "version") ->
          "version is missing (the format version, #{version})"

        document["version"] != version ->
          "version #{inspect(document["version"])} is not supported (expected #{version})"

        not is_list(monitors) ->
          "monitors must be a list"

        length(monitors) > @max_monitors ->
          "the file has more than #{@max_monitors} monitors"

        true ->
          nil
      end

    if message, do: {:error, [file_error(message)]}, else: {:ok, monitors}
  end

  defp document(_document),
    do: {:error, [file_error("expected a mapping with version and monitors")]}

  defp entry(%{} = monitor, index) do
    name = monitor["name"]
    name = if is_binary(name), do: String.trim(name), else: name
    error = &%Error{index: index, name: if(is_binary(name), do: name), field: &1, message: &2}

    case entry_errors(monitor, name, error) do
      [] ->
        {:ok,
         %{
           index: index,
           name: name,
           attrs: attrs(monitor, name),
           parent: blank_to_nil(monitor["parent"]),
           channels: Enum.map(monitor["channels"] || [], &String.trim/1),
           push_token?: is_binary((monitor["settings"] || %{})["push_token"])
         }}

      errors ->
        {:error, errors}
    end
  end

  defp entry(_monitor, index),
    do: {:error, [%Error{index: index, message: "must be a mapping with name, type, ..."}]}

  defp entry_errors(monitor, name, error) do
    errors =
      List.flatten([
        for(key <- Map.keys(monitor) -- @monitor_keys, do: unknown_key(error, key)),
        check(is_binary(name) and name != "", error.("name", "must be a non-empty string")),
        check_type(monitor["type"], error),
        check(
          is_nil(monitor["parent"]) or is_binary(monitor["parent"]),
          error.("parent", "must be the name of a monitor")
        ),
        check(
          channel_names?(monitor["channels"]),
          error.("channels", "must be a list of notification channel names")
        ),
        check(
          is_nil(monitor["settings"]) or is_map(monitor["settings"]),
          error.("settings", "must be a mapping")
        )
      ])

    if errors == [],
      do: check_settings(monitor["settings"] || %{}, monitor["type"], error),
      else: errors
  end

  defp channel_names?(nil), do: true
  defp channel_names?(names) when is_list(names), do: Enum.all?(names, &is_binary/1)
  defp channel_names?(_names), do: false

  defp unknown_key(error, "secrets"),
    do: error.("secrets", "can't be imported, set secrets in the UI")

  defp unknown_key(error, key), do: error.(key, "is not a monitor field")

  defp check(true, _error), do: []
  defp check(false, error), do: [error]

  defp check_type(type, error) do
    cond do
      is_nil(type) -> [error.("type", "is missing")]
      type_atom(type) -> []
      true -> [error.("type", "must be one of #{Enum.join(Monitor.types(), ", ")}")]
    end
  end

  defp type_atom(type), do: Enum.find(Monitor.types(), &(Atom.to_string(&1) == type))

  defp check_settings(settings, type, error) do
    known = type |> type_atom() |> Settings.fields_for() |> Enum.map(&Atom.to_string/1)

    for key <- Map.keys(settings) -- known,
        do: error.("settings." <> key, "is not a setting of #{type} monitors")
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(_value), do: nil

  # The params of a complete monitor: what the file doesn't say gets its
  # default. The parent is set in a second pass; secrets aren't touched.
  defp attrs(monitor, name) do
    defaults = %Monitor{}
    type = type_atom(monitor["type"])
    settings = monitor["settings"] || %{}

    schedule =
      Map.new(@schedule_fields, fn field ->
        key = Atom.to_string(field)
        {key, default(monitor[key], Map.fetch!(defaults, field))}
      end)

    Map.merge(schedule, %{
      "name" => name,
      "type" => monitor["type"],
      "description" => monitor["description"],
      "labels" => monitor["labels"] || %{},
      "settings" =>
        Map.new(Settings.fields_for(type), fn field ->
          key = Atom.to_string(field)
          {key, settings[key]}
        end)
    })
  end

  defp default(nil, default), do: default
  defp default(value, _default), do: value

  defp check_duplicate_names(results) do
    {results, _seen} =
      Enum.map_reduce(results, MapSet.new(), fn
        {:ok, %{name: name} = entry} = ok, seen ->
          if MapSet.member?(seen, name) do
            error = %Error{
              index: entry.index,
              name: name,
              field: "name",
              message: "is used by another monitor in the file"
            }

            {{:error, [error]}, seen}
          else
            {ok, MapSet.put(seen, name)}
          end

        error, seen ->
          {error, seen}
      end)

    results
  end

  defp collect(results) do
    case Enum.flat_map(results, &errors/1) do
      [] -> {:ok, Enum.map(results, fn {:ok, entry} -> entry end)}
      errors -> {:error, errors}
    end
  end

  defp errors({:ok, _value}), do: []
  defp errors({:error, errors}), do: errors

  defp file_error(message), do: %Error{message: message}

  ## Planning

  # Resolves names against the database and validates every monitor; returns
  # the steps to take or every error found.
  @spec plan([entry()], keyword()) :: {:ok, map()} | {:error, [Error.t()]}
  defp plan(entries, opts) do
    monitors = Repo.all(Monitor)

    with {steps, []} <- steps(entries, MapSet.new(entries, & &1.name), monitors),
         [] <- push_token_errors(steps, monitors),
         [] <- cycle_errors(steps, monitors) do
      {:ok, %{steps: resolve_file_parents(steps), missing: missing(entries, opts)}}
    else
      {_steps, errors} -> {:error, errors}
      errors when is_list(errors) -> {:error, errors}
    end
  end

  # A step per monitor (what to write), and the errors of those that can't
  # be written. `file_names` are the names a parent can refer to.
  defp steps(entries, file_names, monitors) do
    by_name = Enum.group_by(monitors, & &1.name)
    channels = Enum.group_by(Repo.all(Channel), & &1.name)
    current_channels = current_channel_ids(monitors)

    results =
      Enum.map(entries, fn entry ->
        with {:ok, existing} <- existing(entry, by_name),
             {:ok, channel_ids} <- channel_ids(entry, channels),
             {:ok, parent} <- parent(entry, file_names, by_name) do
          step(entry, existing, channel_ids, parent, current_channels)
        end
      end)

    {for({:ok, step} <- results, do: step), Enum.flat_map(results, &errors/1)}
  end

  defp existing(entry, by_name) do
    case Map.get(by_name, entry.name, []) do
      [] ->
        {:ok, nil}

      [monitor] ->
        {:ok, monitor}

      monitors ->
        {:error,
         [
           entry_error(
             entry,
             "name",
             "matches #{length(monitors)} existing monitors, rename them so names are unique"
           )
         ]}
    end
  end

  defp channel_ids(entry, channels) do
    entry.channels
    |> Enum.map(fn name ->
      case Map.get(channels, name, []) do
        [channel] -> {:ok, channel.id}
        [] -> {:error, [entry_error(entry, "channels", "#{inspect(name)} doesn't exist")]}
        _more -> {:error, [entry_error(entry, "channels", "#{inspect(name)} is ambiguous")]}
      end
    end)
    |> collect()
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  # `{:file, name}` (a monitor of the file), `{:id, id}` (an existing
  # monitor that isn't in the file) or `nil`.
  defp parent(%{parent: nil}, _file_names, _by_name), do: {:ok, nil}

  defp parent(%{parent: name, name: name} = entry, _file_names, _by_name),
    do: {:error, [entry_error(entry, "parent", "can't be the monitor itself")]}

  defp parent(%{parent: name} = entry, file_names, by_name) do
    if MapSet.member?(file_names, name) do
      {:ok, {:file, name}}
    else
      case Map.get(by_name, name, []) do
        [monitor] -> {:ok, {:id, monitor.id}}
        [] -> {:error, [entry_error(entry, "parent", "#{inspect(name)} doesn't exist")]}
        _more -> {:error, [entry_error(entry, "parent", "#{inspect(name)} is ambiguous")]}
      end
    end
  end

  defp step(entry, existing, channel_ids, parent, current_channels) do
    attrs = put_push_token(entry, existing)
    changeset = Monitor.changeset(existing || %Monitor{}, attrs)

    if changeset.valid? do
      {:ok,
       %{
         entry: entry,
         existing: existing,
         attrs: attrs,
         changed: changed_fields(changeset),
         channel_ids: channel_ids,
         channels_changed?:
           existing == nil or Map.get(current_channels, existing.id, []) != channel_ids,
         parent: parent
       }}
    else
      {:error, changeset_errors(entry, changeset)}
    end
  end

  # Without a token in the file an updated push monitor keeps its own.
  defp put_push_token(%{push_token?: true} = entry, _existing), do: entry.attrs

  defp put_push_token(
         %{attrs: %{"type" => "push"}} = entry,
         %Monitor{type: :push, settings: %{push_token: token}}
       )
       when is_binary(token),
       do: put_in(entry.attrs, ["settings", "push_token"], token)

  defp put_push_token(entry, _existing), do: entry.attrs

  defp changed_fields(changeset) do
    settings =
      case changeset.changes do
        %{settings: %Ecto.Changeset{changes: changes}} ->
          changes |> Map.keys() |> Enum.map(&"settings.#{&1}") |> Enum.sort()

        _no_settings_change ->
          []
      end

    fields =
      changeset.changes
      |> Map.drop([:settings, :auto_labels, :secrets])
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    fields ++ settings
  end

  defp changeset_errors(entry, changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> flatten_errors([])
    |> Enum.map(fn {field, message} -> entry_error(entry, field, message) end)
  end

  defp flatten_errors(errors, path) do
    Enum.flat_map(errors, fn
      {key, %{} = nested} ->
        flatten_errors(nested, path ++ [Atom.to_string(key)])

      {key, messages} when is_list(messages) ->
        field = Enum.join(path ++ [Atom.to_string(key)], ".")
        Enum.map(messages, &{field, &1})
    end)
    |> Enum.sort()
  end

  defp interpolate({message, opts}) do
    values = Map.new(opts, fn {key, value} -> {Atom.to_string(key), value} end)

    Regex.replace(~r"%{(\w+)}", message, fn match, key ->
      values |> Map.get(key, match) |> to_string()
    end)
  end

  defp entry_error(entry, field, message),
    do: %Error{index: entry.index, name: entry.name, field: field, message: message}

  # monitor id => sorted channel ids.
  defp current_channel_ids(monitors) do
    ids = Enum.map(monitors, & &1.id)

    from(mc in "monitor_notification_channels",
      where: mc.monitor_id in ^ids,
      select: {mc.monitor_id, mc.channel_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, channel_ids} -> {id, Enum.sort(channel_ids)} end)
  end

  # Push tokens given in the file must be unique, among each other and the
  # monitors that keep theirs (checked here so a dry run reports it).
  defp push_token_errors(steps, monitors) do
    replaced = MapSet.new(steps, &(&1.existing && &1.existing.id))

    kept =
      for %Monitor{type: :push, settings: %{push_token: token}} = monitor <- monitors,
          not MapSet.member?(replaced, monitor.id),
          into: MapSet.new(),
          do: token

    {errors, _seen} =
      steps
      |> Enum.filter(& &1.entry.push_token?)
      |> Enum.flat_map_reduce(kept, fn step, seen ->
        token = get_in(step.attrs, ["settings", "push_token"])

        if MapSet.member?(seen, token),
          do: {[entry_error(step.entry, "settings.push_token", "is already in use")], seen},
          else: {[], MapSet.put(seen, token)}
      end)

    errors
  end

  # The parents after the import, of the monitors in the file and the
  # others, must not form a cycle. Any cycle goes through a monitor of the
  # file, as only their parents change.
  defp cycle_errors(steps, monitors) do
    node = fn step -> if step.existing, do: step.existing.id, else: {:new, step.entry.name} end
    by_name = Map.new(steps, &{&1.entry.name, node.(&1)})

    parents =
      Map.merge(
        Map.new(monitors, &{&1.id, &1.parent_id}),
        Map.new(steps, fn step -> {node.(step), parent_node(step.parent, by_name)} end)
      )

    for step <- steps, cycle?(node.(step), parents) do
      entry_error(step.entry, "parent", "would create a dependency cycle")
    end
  end

  # A parent named in the file is the id of the existing monitor, or `:new`
  # if the import creates it (so it's always a change).
  defp resolve_file_parents(steps) do
    ids = Map.new(steps, &{&1.entry.name, if(&1.existing, do: &1.existing.id, else: :new)})

    Enum.map(steps, fn
      %{parent: {:file, name}} = step -> Map.put(step, :parent_id, Map.fetch!(ids, name))
      step -> step
    end)
  end

  defp parent_node(nil, _by_name), do: nil
  defp parent_node({:id, id}, _by_name), do: id
  defp parent_node({:file, name}, by_name), do: Map.fetch!(by_name, name)

  defp cycle?(start, parents), do: cycle?(Map.get(parents, start), start, parents, MapSet.new())

  defp cycle?(nil, _start, _parents, _seen), do: false
  defp cycle?(start, start, _parents, _seen), do: true

  defp cycle?(node, start, parents, seen) do
    if MapSet.member?(seen, node),
      do: false,
      else: cycle?(Map.get(parents, node), start, parents, MapSet.put(seen, node))
  end

  defp missing(entries, opts) do
    if Keyword.get(opts, :missing, :ignore) == :report do
      names = MapSet.new(entries, & &1.name)

      [selector: opts[:selector]]
      |> Monitoring.list_monitors()
      |> Enum.map(& &1.name)
      |> Enum.reject(&MapSet.member?(names, &1))
    end
  end

  ## Importing

  defp result(%{steps: steps, missing: missing}) do
    changes =
      Enum.map(steps, fn step ->
        fields = step_fields(step)

        action =
          cond do
            step.existing == nil -> :create
            fields == [] -> :unchanged
            true -> :update
          end

        %Change{
          action: action,
          name: step.entry.name,
          monitor: step.existing,
          fields: if(action == :update, do: fields, else: [])
        }
      end)

    %Result{changes: changes, missing: missing}
  end

  defp step_fields(step) do
    step.changed ++
      if(parent_changed?(step), do: ["parent"], else: []) ++
      if(step.channels_changed?, do: ["channels"], else: [])
  end

  defp parent_changed?(%{existing: nil, parent: parent}), do: parent != nil
  defp parent_changed?(%{existing: existing, parent: nil}), do: existing.parent_id != nil
  defp parent_changed?(%{existing: existing, parent: {:id, id}}), do: existing.parent_id != id

  defp parent_changed?(%{existing: existing, parent: {:file, _name}, parent_id: id}),
    do: existing.parent_id != id

  defp dry_run(entries, opts) do
    with {:ok, plan} <- plan(entries, opts), do: {:ok, %{result(plan) | dry_run: true}}
  end

  defp import_entries(entries, opts) do
    Monitoring.transaction(fn ->
      with {:ok, plan} <- plan(entries, opts),
           {:ok, monitors} <- write(plan) do
        result = result(plan)

        changes =
          Enum.map(result.changes, &%{&1 | monitor: Map.fetch!(monitors, &1.name)})

        %{result | changes: changes}
      else
        {:error, errors} -> Repo.rollback(errors)
      end
    end)
  end

  # Creates and updates the monitors and their channels, then sets the
  # parents: first detaching the monitors whose parent changes, then
  # attaching the new parents, so no intermediate state has a cycle that
  # the final one doesn't have (it has none). Returns name => monitor.
  defp write(%{steps: steps}) do
    with {:ok, monitors} <- reduce_ok(steps, %{}, &write_monitor/2),
         {:ok, monitors} <- reduce_ok(steps, monitors, &detach_parent/2) do
      reduce_ok(steps, monitors, &attach_parent/2)
    end
  end

  defp reduce_ok(steps, acc, fun) do
    Enum.reduce_while(steps, {:ok, acc}, fn step, {:ok, acc} ->
      case fun.(step, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _errors} = error -> {:halt, error}
      end
    end)
  end

  defp write_monitor(%{existing: nil} = step, monitors) do
    with {:ok, monitor} <- check_write(step, Monitoring.create_monitor(step.attrs)) do
      :ok = Notifications.put_monitor_channels(monitor, step.channel_ids)
      {:ok, Map.put(monitors, step.entry.name, monitor)}
    end
  end

  defp write_monitor(step, monitors) do
    result =
      if step.changed == [],
        do: {:ok, step.existing},
        else: Monitoring.update_monitor(step.existing, step.attrs)

    with {:ok, monitor} <- check_write(step, result) do
      if step.channels_changed?,
        do: :ok = Notifications.put_monitor_channels(monitor, step.channel_ids)

      {:ok, Map.put(monitors, step.entry.name, monitor)}
    end
  end

  defp detach_parent(step, monitors) do
    monitor = Map.fetch!(monitors, step.entry.name)

    if monitor.parent_id != nil and monitor.parent_id != parent_id(step, monitors),
      do: put_parent(step, monitors, monitor, nil),
      else: {:ok, monitors}
  end

  defp attach_parent(step, monitors) do
    monitor = Map.fetch!(monitors, step.entry.name)

    case parent_id(step, monitors) do
      nil -> {:ok, monitors}
      id when id == monitor.parent_id -> {:ok, monitors}
      id -> put_parent(step, monitors, monitor, id)
    end
  end

  defp parent_id(%{parent: nil}, _monitors), do: nil
  defp parent_id(%{parent: {:id, id}}, _monitors), do: id
  defp parent_id(%{parent: {:file, name}}, monitors), do: Map.fetch!(monitors, name).id

  defp put_parent(step, monitors, monitor, parent_id) do
    with {:ok, monitor} <-
           check_write(step, Monitoring.update_monitor(monitor, %{"parent_id" => parent_id})) do
      {:ok, Map.put(monitors, step.entry.name, monitor)}
    end
  end

  defp check_write(_step, {:ok, monitor}), do: {:ok, monitor}

  defp check_write(step, {:error, %Ecto.Changeset{} = changeset}),
    do: {:error, changeset_errors(step.entry, changeset)}
end
