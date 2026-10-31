defmodule SentinelixWeb.MaintenanceLive.Form do
  @moduledoc """
  Create and edit maintenance windows (`/maintenance/new`,
  `/maintenance/:id/edit`).

  Dates and times are entered in the window's time zone.

  The window applies to all monitors, to selected monitors, or to the
  monitors matching a label selector (`Sentinelix.Monitoring.Selector`,
  without `status` terms) plus, optionally, selected ones. The selector
  input previews the monitors it matches now as you type; the window
  follows later label changes by itself.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.SelectorComponents

  alias Sentinelix.{Maintenance, Monitoring}
  alias Sentinelix.Maintenance.Window
  alias Sentinelix.Monitoring.Selector

  @scopes [
    {"all", "All monitors", "Including monitors created later."},
    {"monitors", "Selected monitors", nil},
    {"selector", "Matching a selector",
     "Monitors with matching labels, including ones labeled later."}
  ]

  # Monitors listed in the selector preview; the rest are counted.
  @preview_limit 20

  @weekdays [{1, "Mon"}, {2, "Tue"}, {3, "Wed"}, {4, "Thu"}, {5, "Fri"}, {6, "Sat"}, {7, "Sun"}]

  # Suggestions for the time zone input; any IANA time zone name is accepted.
  @timezones ~w(
    Etc/UTC Europe/London Europe/Dublin Europe/Lisbon Europe/Oslo Europe/Stockholm
    Europe/Copenhagen Europe/Helsinki Europe/Berlin Europe/Amsterdam Europe/Brussels
    Europe/Paris Europe/Madrid Europe/Rome Europe/Warsaw Europe/Athens Europe/Moscow
    America/New_York America/Chicago America/Denver America/Phoenix America/Los_Angeles
    America/Anchorage America/Toronto America/Vancouver America/Mexico_City
    America/Sao_Paulo America/Argentina/Buenos_Aires Pacific/Honolulu Africa/Johannesburg
    Africa/Lagos Africa/Cairo Asia/Dubai Asia/Kolkata Asia/Singapore Asia/Shanghai
    Asia/Hong_Kong Asia/Tokyo Asia/Seoul Australia/Perth Australia/Sydney Pacific/Auckland
  )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:maintenance}>
      <div>
        <.link navigate={~p"/maintenance"} class="text-sm text-base-content/60 hover:underline">
          <.icon name="hero-arrow-left-micro" class="size-4" /> Maintenance
        </.link>
        <.header>
          {@page_title}
          <:subtitle>
            Checks keep running; results are recorded as maintenance and don't alert.
          </:subtitle>
        </.header>
      </div>

      <.form
        for={@form}
        id="window-form"
        phx-change="validate"
        phx-submit="save"
        class="grid gap-4 lg:grid-cols-3"
      >
        <div class="space-y-4 lg:col-span-2">
          <section class="rounded-box border border-base-300 bg-base-100 p-4 sm:p-6">
            <h2 class="mb-3 font-semibold">General</h2>
            <.input
              field={@form[:title]}
              type="text"
              label="Title"
              placeholder="Database upgrade"
              phx-debounce="300"
            />
            <.input
              field={@form[:description]}
              type="textarea"
              label="Description (optional)"
              rows="2"
              phx-debounce="300"
            />
            <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
          </section>

          <section
            id="window-schedule"
            class="rounded-box border border-base-300 bg-base-100 p-4 sm:p-6"
          >
            <h2 class="mb-3 font-semibold">Schedule</h2>
            <div class="grid gap-x-4 sm:grid-cols-2">
              <.input
                field={@form[:recurrence]}
                type="select"
                label="Repeat"
                options={[{"Once", :once}, {"Daily", :daily}, {"Weekly", :weekly}]}
              />
              <.input
                field={@form[:timezone]}
                type="text"
                label="Time zone"
                list="timezones"
                autocomplete="off"
                phx-debounce="300"
              />
              <datalist id="timezones">
                <option :for={tz <- timezones()} value={tz} />
              </datalist>
            </div>

            <div :if={@recurrence == :once} id="once-fields" class="grid gap-x-4 sm:grid-cols-2">
              <.input field={@form[:local_starts_at]} type="datetime-local" label="Starts" />
              <.input field={@form[:local_ends_at]} type="datetime-local" label="Ends" />
            </div>

            <div :if={@recurrence != :once} id="recurring-fields">
              <fieldset :if={@recurrence == :weekly} id="window-weekdays" class="fieldset mb-2">
                <legend class="fieldset-legend">Days</legend>
                <input type="hidden" name="window[weekdays][]" value="" />
                <div class="flex flex-wrap gap-3">
                  <label :for={{day, label} <- weekdays()} class="label cursor-pointer gap-1 text-sm">
                    <input
                      type="checkbox"
                      id={"weekday-#{day}"}
                      name="window[weekdays][]"
                      value={day}
                      checked={day in (@form[:weekdays].value || [])}
                      class="checkbox checkbox-sm"
                    />
                    {label}
                  </label>
                </div>
                <p
                  :for={msg <- field_errors(@form, :weekdays)}
                  class="mt-1 flex items-center gap-2 text-sm text-error"
                >
                  <.icon name="hero-exclamation-circle" class="size-5" /> {msg}
                </p>
              </fieldset>
              <div class="grid gap-x-4 sm:grid-cols-2">
                <.input field={@form[:start_time]} type="time" label="Start time" />
                <.input
                  field={@form[:duration_minutes]}
                  type="number"
                  label="Duration (minutes)"
                  min="1"
                />
                <.input
                  field={@form[:local_starts_at]}
                  type="datetime-local"
                  label="Effective from (optional)"
                />
                <.input
                  field={@form[:local_ends_at]}
                  type="datetime-local"
                  label="Effective until (optional)"
                />
              </div>
            </div>
          </section>
        </div>

        <div class="space-y-4">
          <section
            id="window-monitors"
            class="rounded-box border border-base-300 bg-base-100 p-4 sm:p-6"
          >
            <h2 class="mb-3 font-semibold">Monitors</h2>
            <fieldset id="window-scope" class="fieldset mb-2">
              <legend class="sr-only">Applies to</legend>
              <label
                :for={{scope, label, hint} <- scopes()}
                class="label cursor-pointer items-start gap-2 py-1 text-sm whitespace-normal"
              >
                <input
                  type="radio"
                  id={"scope-#{scope}"}
                  name="window[scope]"
                  value={scope}
                  checked={@scope == scope}
                  class="radio radio-sm mt-0.5"
                />
                <span>
                  <span class="text-base-content">{label}</span>
                  <span :if={hint} class="block text-xs text-base-content/60">{hint}</span>
                </span>
              </label>
            </fieldset>

            <div :if={@scope == "selector"} id="selector-fields" class="mb-3">
              <.selector_input
                id="window-selector"
                value={@selector_text}
                error={@selector_error}
                suggestions={@suggestions}
                placeholder="site=oslo, env=prod, name~api"
              />
              <div id="selector-preview" class="mt-2 text-sm">
                <p :if={@selector_error == nil} class="text-xs text-base-content/60">
                  {preview_summary(@selector_text, @preview)}
                </p>
                <ul :if={@preview != []} class="mt-1 space-y-0.5">
                  <li
                    :for={monitor <- Enum.take(@preview, preview_limit())}
                    id={"preview-#{monitor.id}"}
                    class="truncate"
                  >
                    {monitor.name}
                  </li>
                </ul>
                <p :if={length(@preview) > preview_limit()} class="text-xs text-base-content/60">
                  and {length(@preview) - preview_limit()} more
                </p>
              </div>
            </div>

            <%!-- Hidden rather than removed, so the selection survives switching. --%>
            <div id="monitor-choices" class={@scope == "all" && "hidden"}>
              <p :if={@scope == "selector"} class="mb-1 text-xs text-base-content/60">
                Also include (optional):
              </p>
              <input type="hidden" name="window[monitor_ids][]" value="" />
              <p :if={@monitors == []} class="text-sm text-base-content/60">No monitors yet.</p>
              <label
                :for={monitor <- @monitors}
                class="flex cursor-pointer items-center gap-2 py-1 text-sm"
              >
                <input
                  type="checkbox"
                  id={"monitor-#{monitor.id}"}
                  name="window[monitor_ids][]"
                  value={monitor.id}
                  checked={monitor.id in @monitor_ids}
                  class="checkbox checkbox-sm"
                />
                <span class="truncate">{monitor.name}</span>
              </label>
            </div>
            <p
              :for={msg <- field_errors(@form, :monitors)}
              class="mt-1 flex items-center gap-2 text-sm text-error"
            >
              <.icon name="hero-exclamation-circle" class="size-5" /> {msg}
            </p>
          </section>

          <div class="flex gap-2">
            <.button variant="primary" phx-disable-with="Saving..." id="save-window">
              Save window
            </.button>
            <.button navigate={~p"/maintenance"}>Cancel</.button>
          </div>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    # Status terms aren't allowed in windows, so they aren't suggested.
    completion =
      Monitoring.list_label_values(automatic: true)
      |> completion_values()
      |> Map.delete("status")

    socket = assign(socket, monitors: Monitoring.list_monitors(), completion: completion)
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    window = Maintenance.new_window()

    socket
    |> assign(page_title: "New maintenance window", window: window, monitor_ids: [])
    |> assign(scope: "monitors")
    |> assign_selector("")
    |> assign_form(Maintenance.change_window(window))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case parse_id(id) && Maintenance.get_window(parse_id(id)) do
      nil ->
        socket
        |> put_flash(:error, "Maintenance window not found.")
        |> push_navigate(to: ~p"/maintenance")

      window ->
        window = Window.put_local_times(window)

        socket
        |> assign(page_title: "Edit maintenance window", window: window)
        |> assign(monitor_ids: Enum.map(window.monitors, & &1.id), scope: scope(window))
        |> assign_selector(window.selector)
        |> assign_form(Maintenance.change_window(window))
    end
  end

  @impl true
  def handle_event("validate", %{"window" => params} = all_params, socket) do
    socket = assign_inputs(socket, params, all_params)
    params = normalize_params(params, socket.assigns)

    changeset =
      socket.assigns.window
      |> Maintenance.change_window(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"window" => params} = all_params, socket) do
    socket = assign_inputs(socket, params, all_params)
    params = normalize_params(params, socket.assigns)

    result =
      case socket.assigns.live_action do
        :new -> Maintenance.create_window(params)
        :edit -> Maintenance.update_window(socket.assigns.window, params)
      end

    case result do
      {:ok, window} ->
        {:noreply,
         socket
         |> put_flash(:info, "Maintenance window \"#{window.title}\" saved.")
         |> push_navigate(to: ~p"/maintenance")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket,
      form: to_form(changeset, as: :window),
      recurrence: Ecto.Changeset.get_field(changeset, :recurrence)
    )
  end

  # The monitor selection, the scope and the selector text (the selector
  # input is named `selector`, outside of `window`) as entered, kept while
  # switching scopes.
  defp assign_inputs(socket, params, all_params) do
    socket =
      assign(socket,
        monitor_ids: ids(params["monitor_ids"]),
        scope: scope_param(params, socket.assigns.scope)
      )

    case all_params do
      %{"selector" => text} when is_binary(text) -> assign_selector(socket, text)
      _params -> socket
    end
  end

  defp scope_param(%{"scope" => scope}, _current) when scope in ["all", "monitors", "selector"],
    do: scope

  defp scope_param(_params, current), do: current

  defp assign_selector(socket, text) do
    {error, preview} =
      case Selector.parse(text, allow: Window.selector_allow()) do
        {:ok, selector} -> {nil, Maintenance.selector_monitors(selector)}
        {:error, error} -> {error, []}
      end

    assign(socket,
      selector_text: text,
      selector_error: error,
      preview: preview,
      suggestions: suggestions(text, socket.assigns.completion)
    )
  end

  defp scope(%Window{all_monitors: true}), do: "all"
  defp scope(%Window{selector: selector}) when selector not in [nil, ""], do: "selector"
  defp scope(_window), do: "monitors"

  defp preview_summary(text, preview) do
    case {String.trim(text), length(preview)} do
      {"", _count} -> "Enter a selector, e.g. site=oslo."
      {_text, 0} -> "No monitors match now."
      {_text, 1} -> "1 monitor matches now:"
      {_text, count} -> "#{count} monitors match now:"
    end
  end

  # Applies the scope (the selector only counts for "selector") and the
  # monitor selection without the blank values of the hidden inputs that
  # allow empty selections.
  @doc false
  def normalize_params(params, inputs) do
    params
    |> Map.delete("scope")
    |> Map.put("all_monitors", inputs.scope == "all")
    |> Map.put("selector", if(inputs.scope == "selector", do: inputs.selector_text, else: ""))
    |> Map.put("monitor_ids", inputs.monitor_ids)
    |> then(fn params ->
      if Map.has_key?(params, "weekdays"),
        do: Map.put(params, "weekdays", ids(params["weekdays"])),
        else: params
    end)
  end

  defp ids(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      case parse_id(value) do
        nil -> []
        id -> [id]
      end
    end)
  end

  defp parse_id(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp field_errors(form, field) do
    if Phoenix.Component.used_input?(form[field]) or form.source.action == :insert or
         form.source.action == :update do
      Enum.map(form[field].errors, &translate_error/1)
    else
      []
    end
  end

  defp scopes, do: @scopes
  defp preview_limit, do: @preview_limit
  defp weekdays, do: @weekdays
  defp timezones, do: @timezones
end
