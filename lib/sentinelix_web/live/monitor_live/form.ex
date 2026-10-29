defmodule SentinelixWeb.MonitorLive.Form do
  @moduledoc """
  Create and edit monitors. The type-specific settings (an embed) are
  rendered with `inputs_for` from `Sentinelix.Monitoring.Settings.fields_for/1`
  and re-rendered when the type changes.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents

  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{Monitor, Settings}
  alias Sentinelix.Notifications

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:monitors}>
      <div>
        <.link navigate={@return_to} class="text-sm text-base-content/60 hover:underline">
          <.icon name="hero-arrow-left-micro" class="size-4" /> Back
        </.link>
        <.header>
          {@page_title}
          <:subtitle>
            {if @live_action == :new,
              do: "Choose what to monitor and how often to check it.",
              else: @monitor.name}
          </:subtitle>
        </.header>
      </div>

      <.form
        for={@form}
        id="monitor-form"
        phx-change="validate"
        phx-submit="save"
        class="grid gap-4 lg:grid-cols-3"
      >
        <div class="space-y-4 lg:col-span-2">
          <section class="rounded-box border border-base-300 bg-base-100 p-4 sm:p-6">
            <h2 class="mb-3 font-semibold">General</h2>
            <div class="grid gap-x-4 sm:grid-cols-2">
              <.input
                field={@form[:type]}
                type="select"
                label="Monitor type"
                options={type_options()}
              />
              <.input
                field={@form[:name]}
                type="text"
                label="Name"
                placeholder="My website"
                phx-debounce="300"
              />
            </div>
            <p class="text-xs text-base-content/60">{type_help(@type)}</p>
          </section>

          <section
            :if={@type}
            id="settings-fields"
            data-type={@type}
            class="rounded-box border border-base-300 bg-base-100 p-4 sm:p-6"
          >
            <h2 class="mb-3 font-semibold">{type_label(@type)} settings</h2>
            <.inputs_for :let={settings} field={@form[:settings]}>
              <div class="grid gap-x-4 sm:grid-cols-2">
                <.settings_field
                  :for={name <- Settings.fields_for(@type)}
                  name={name}
                  field={settings[name]}
                  type={@type}
                />
              </div>
            </.inputs_for>
          </section>

          <section class="rounded-box border border-base-300 bg-base-100 p-4 sm:p-6">
            <h2 class="mb-3 font-semibold">Description & tags</h2>
            <.input
              field={@form[:tags]}
              type="text"
              label="Tags"
              value={format_list(@form[:tags].value)}
              placeholder="production, web"
              phx-debounce="300"
            />
            <p class="-mt-1 mb-2 text-xs text-base-content/60">Comma separated.</p>
            <.input
              field={@form[:description]}
              type="textarea"
              label="Description"
              rows="2"
              phx-debounce="300"
            />
          </section>
        </div>

        <div class="space-y-4">
          <section class="rounded-box border border-base-300 bg-base-100 p-4 sm:p-6">
            <h2 class="mb-3 font-semibold">Schedule</h2>
            <.input
              field={@form[:interval_seconds]}
              type="number"
              label="Check interval (seconds)"
              min={Monitor.min_interval_seconds()}
            />
            <.input field={@form[:max_retries]} type="number" label="Retries before down" min="0" />
            <.input
              field={@form[:retry_interval_seconds]}
              type="number"
              label="Retry interval (seconds)"
              min={Monitor.min_interval_seconds()}
            />
            <.input field={@form[:timeout_ms]} type="number" label="Timeout (ms)" min="100" />
            <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
          </section>

          <section
            id="monitor-notifications"
            class="rounded-box border border-base-300 bg-base-100 p-4 sm:p-6"
          >
            <h2 class="mb-3 font-semibold">Notifications</h2>
            <input type="hidden" name="channel_ids[]" value="" />
            <p :if={@channels == []} class="text-sm text-base-content/60">
              No notification channels yet.
              <.link navigate={~p"/settings/notifications/new"} class="link">Add one</.link>
            </p>
            <label
              :for={channel <- @channels}
              class="flex cursor-pointer items-center gap-2 py-1 text-sm"
            >
              <input
                type="checkbox"
                id={"channel-#{channel.id}"}
                name="channel_ids[]"
                value={channel.id}
                checked={channel.id in @channel_ids}
                class="checkbox checkbox-sm"
              />
              <span class="truncate">{channel.name}</span>
              <span class="badge badge-ghost badge-xs">{channel.type}</span>
              <span :if={!channel.enabled} class="badge badge-warning badge-soft badge-xs">
                disabled
              </span>
            </label>
          </section>

          <div class="flex gap-2">
            <.button
              variant="primary"
              phx-disable-with="Saving..."
              id="save-monitor"
              class="btn btn-primary flex-1"
            >
              <.icon name="hero-check" class="size-4" />
              {if @live_action == :new, do: "Create monitor", else: "Save changes"}
            </.button>
            <.link navigate={@return_to} class="btn btn-ghost">Cancel</.link>
          </div>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  attr :name, :atom, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :type, :atom, required: true

  defp settings_field(%{name: :url} = assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.input
        field={@field}
        type="url"
        label="URL"
        placeholder="https://example.com/health"
        phx-debounce="300"
      />
    </div>
    """
  end

  defp settings_field(%{name: :method} = assigns) do
    ~H"""
    <.input field={@field} type="select" label="Method" options={Settings.http_methods()} />
    """
  end

  defp settings_field(%{name: :headers} = assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.input
        field={@field}
        type="textarea"
        label="Request headers"
        value={format_headers(@field.value)}
        rows="3"
        placeholder="Authorization: Bearer ..."
        class="w-full textarea font-mono text-sm"
        phx-debounce="300"
      />
      <p class="-mt-1 mb-2 text-xs text-base-content/60">One "Name: value" per line.</p>
    </div>
    """
  end

  defp settings_field(%{name: :body} = assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.input
        field={@field}
        type="textarea"
        label="Request body"
        rows="3"
        class="w-full textarea font-mono text-sm"
        phx-debounce="300"
      />
    </div>
    """
  end

  defp settings_field(%{name: :accepted_status_codes} = assigns) do
    ~H"""
    <div>
      <.input
        field={@field}
        type="text"
        label="Accepted status codes"
        value={format_list(@field.value)}
        placeholder="200-299, 301"
        phx-debounce="300"
      />
      <p class="-mt-1 mb-2 text-xs text-base-content/60">
        Comma separated codes or ranges. Empty: 200–399 (200–299 without redirects).
      </p>
    </div>
    """
  end

  defp settings_field(%{name: :max_redirects} = assigns) do
    ~H"""
    <.input field={@field} type="number" label="Max. redirects" min="0" max="20" />
    """
  end

  defp settings_field(%{name: :keyword} = assigns) do
    ~H"""
    <.input field={@field} type="text" label="Keyword" placeholder="OK" phx-debounce="300" />
    """
  end

  defp settings_field(%{name: name} = assigns)
       when name in [:follow_redirects, :verify_tls, :invert_keyword, :case_sensitive] do
    ~H"""
    <.input field={@field} type="checkbox" label={checkbox_label(@name)} />
    """
  end

  defp settings_field(%{name: :host} = assigns) do
    ~H"""
    <.input
      field={@field}
      type="text"
      label={if @type == :dns, do: "Hostname to resolve", else: "Hostname or IP address"}
      placeholder="example.com"
      phx-debounce="300"
    />
    """
  end

  defp settings_field(%{name: :port} = assigns) do
    ~H"""
    <.input field={@field} type="number" label="Port" min="1" max="65535" />
    """
  end

  defp settings_field(%{name: :dns_record_type} = assigns) do
    ~H"""
    <.input field={@field} type="select" label="Record type" options={Settings.dns_record_types()} />
    """
  end

  defp settings_field(%{name: :dns_resolver} = assigns) do
    ~H"""
    <.input
      field={@field}
      type="text"
      label="Resolver (optional)"
      placeholder="1.1.1.1"
      phx-debounce="300"
    />
    """
  end

  defp settings_field(%{name: :expected_value} = assigns) do
    ~H"""
    <.input
      field={@field}
      type="text"
      label="Expected value (optional)"
      placeholder="192.0.2.1"
      phx-debounce="300"
    />
    """
  end

  defp settings_field(%{name: :cert_warn_days} = assigns) do
    ~H"""
    <.input field={@field} type="number" label="Warn when expiring within (days)" min="1" />
    """
  end

  defp settings_field(%{name: :cert_critical_days} = assigns) do
    ~H"""
    <.input field={@field} type="number" label="Down when expiring within (days)" min="1" />
    """
  end

  defp settings_field(%{name: :push_token} = assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.input field={@field} type="text" label="Push token" readonly class="w-full input font-mono" />
      <div
        id="push-url-preview"
        class="mb-2 flex flex-wrap items-center gap-2 text-xs text-base-content/60"
      >
        <span>Push URL:</span>
        <code class="break-all">{push_url(@field.value)}</code>
        <button
          type="button"
          phx-click="regenerate_token"
          class="btn btn-ghost btn-xs"
          id="regenerate-token"
        >
          <.icon name="hero-arrow-path-micro" class="size-3" /> Regenerate
        </button>
      </div>
    </div>
    """
  end

  defp settings_field(assigns) do
    ~H"""
    <.input field={@field} type="text" label={Phoenix.Naming.humanize(@name)} />
    """
  end

  defp checkbox_label(:follow_redirects), do: "Follow redirects"
  defp checkbox_label(:verify_tls), do: "Verify TLS certificate"
  defp checkbox_label(:invert_keyword), do: "Down if the keyword is found"
  defp checkbox_label(:case_sensitive), do: "Case sensitive"

  defp type_help(:http), do: "Checks that a URL responds with an accepted HTTP status code."
  defp type_help(:keyword), do: "Checks that a URL's response body contains a keyword."
  defp type_help(:tcp), do: "Checks that a TCP port accepts connections."
  defp type_help(:ping), do: "Checks that a host answers ICMP echo requests."
  defp type_help(:dns), do: "Resolves a hostname and optionally compares the answer."
  defp type_help(:cert), do: "Warns before a TLS certificate expires."

  defp type_help(:push),
    do: "Passive monitor: your service calls the push URL; it goes down when the pushes stop."

  defp type_help(_type), do: nil

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, channels: Notifications.list_channels())
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    monitor = %Monitor{type: :http}

    socket
    |> assign(page_title: "New monitor", monitor: monitor, return_to: ~p"/monitors")
    |> assign(channel_ids: Enum.map(Notifications.list_default_channels(), & &1.id))
    |> assign_form(Monitoring.change_monitor(monitor), %{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case parse_id(id) && Monitoring.get_monitor(parse_id(id)) do
      nil ->
        socket
        |> put_flash(:error, "Monitor not found.")
        |> push_navigate(to: ~p"/monitors")

      monitor ->
        socket
        |> assign(
          page_title: "Edit monitor",
          monitor: monitor,
          return_to: ~p"/monitors/#{monitor}"
        )
        |> assign(channel_ids: Notifications.monitor_channel_ids(monitor))
        |> assign_form(Monitoring.change_monitor(monitor), %{})
    end
  end

  @impl true
  def handle_event("validate", %{"monitor" => params} = all_params, socket) do
    params = normalize_params(params)
    changeset = Monitoring.change_monitor(socket.assigns.monitor, params)

    {:noreply,
     socket
     |> assign(channel_ids: channel_ids(all_params))
     |> assign_form(Map.put(changeset, :action, :validate), params)}
  end

  def handle_event("regenerate_token", _params, socket) do
    params =
      socket.assigns.params
      |> Map.put("type", "push")
      |> Map.update("settings", %{"push_token" => Settings.generate_token()}, fn settings ->
        Map.put(settings || %{}, "push_token", Settings.generate_token())
      end)

    changeset = Monitoring.change_monitor(socket.assigns.monitor, params)
    {:noreply, assign_form(socket, changeset, params)}
  end

  def handle_event("save", %{"monitor" => params} = all_params, socket) do
    socket
    |> assign(channel_ids: channel_ids(all_params))
    |> save(socket.assigns.live_action, normalize_params(params))
  end

  # Selected notification channel ids (the hidden "" input allows none).
  defp channel_ids(params) do
    params
    |> Map.get("channel_ids", [])
    |> List.wrap()
    |> Enum.flat_map(fn id ->
      case Integer.parse(id) do
        {id, ""} -> [id]
        _ -> []
      end
    end)
  end

  defp save(socket, :new, params) do
    case Monitoring.create_monitor(params) do
      {:ok, monitor} ->
        :ok = Notifications.put_monitor_channels(monitor, socket.assigns.channel_ids)

        {:noreply,
         socket
         |> put_flash(:info, "Monitor created.")
         |> push_navigate(to: ~p"/monitors/#{monitor}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset, params)}
    end
  end

  defp save(socket, :edit, params) do
    case Monitoring.update_monitor(socket.assigns.monitor, params) do
      {:ok, monitor} ->
        :ok = Notifications.put_monitor_channels(monitor, socket.assigns.channel_ids)

        {:noreply,
         socket
         |> put_flash(:info, "Monitor updated.")
         |> push_navigate(to: ~p"/monitors/#{monitor}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset, params)}
    end
  end

  defp assign_form(socket, changeset, params) do
    assign(socket,
      form: to_form(changeset),
      type: Ecto.Changeset.get_field(changeset, :type),
      params: params
    )
  end

  ## Params

  # The form uses plain text inputs for list and map fields; turn them into
  # the shapes the changeset casts.
  @doc false
  def normalize_params(params) do
    params
    |> update_present("tags", &split_list(&1, ~r/,/))
    |> update_present("settings", fn settings ->
      settings
      |> update_present("accepted_status_codes", &split_list(&1, ~r/[,\s]+/))
      |> update_present("headers", &parse_headers/1)
    end)
  end

  defp update_present(map, key, fun) when is_map(map) do
    case map do
      %{^key => value} -> Map.put(map, key, fun.(value))
      _ -> map
    end
  end

  defp update_present(other, _key, _fun), do: other

  defp split_list(value, separator) when is_binary(value) do
    value
    |> String.split(separator, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_list(value, _separator), do: value

  defp parse_headers(value) when is_binary(value) do
    value
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Map.new(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, header_value] -> {String.trim(name), String.trim(header_value)}
        [name] -> {name, ""}
      end
    end)
  end

  defp parse_headers(value), do: value

  defp format_list(list) when is_list(list), do: Enum.join(list, ", ")
  defp format_list(value), do: value

  defp format_headers(headers) when is_map(headers) do
    headers
    |> Enum.sort()
    |> Enum.map_join("\n", fn {name, value} -> "#{name}: #{value}" end)
  end

  defp format_headers(value), do: value

  defp parse_id(id) do
    case Integer.parse(id) do
      {id, ""} -> id
      _ -> nil
    end
  end
end
