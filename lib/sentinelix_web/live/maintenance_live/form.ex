defmodule SentinelixWeb.MaintenanceLive.Form do
  @moduledoc """
  Create and edit maintenance windows (`/maintenance/new`,
  `/maintenance/:id/edit`).

  Dates and times are entered in the window's time zone.
  """

  use SentinelixWeb, :live_view

  alias Sentinelix.{Maintenance, Monitoring}
  alias Sentinelix.Maintenance.Window

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
            <.input field={@form[:all_monitors]} type="checkbox" label="All monitors" />
            <%!-- Hidden rather than removed, so the selection survives toggling. --%>
            <div id="monitor-choices" class={@all_monitors && "hidden"}>
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
    socket = assign(socket, monitors: Monitoring.list_monitors())
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    window = Maintenance.new_window()

    socket
    |> assign(page_title: "New maintenance window", window: window, monitor_ids: [])
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
        |> assign(monitor_ids: Enum.map(window.monitors, & &1.id))
        |> assign_form(Maintenance.change_window(window))
    end
  end

  @impl true
  def handle_event("validate", %{"window" => params}, socket) do
    params = normalize_params(params)

    changeset =
      socket.assigns.window
      |> Maintenance.change_window(params)
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign(monitor_ids: params["monitor_ids"]) |> assign_form(changeset)}
  end

  def handle_event("save", %{"window" => params}, socket) do
    params = normalize_params(params)
    socket = assign(socket, monitor_ids: params["monitor_ids"])

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
      recurrence: Ecto.Changeset.get_field(changeset, :recurrence),
      all_monitors: Ecto.Changeset.get_field(changeset, :all_monitors)
    )
  end

  # Drops the blank values of the hidden inputs that allow empty selections.
  @doc false
  def normalize_params(params) do
    params
    |> Map.put("monitor_ids", ids(params["monitor_ids"]))
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

  defp weekdays, do: @weekdays
  defp timezones, do: @timezones
end
