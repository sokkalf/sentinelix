defmodule SentinelixWeb.MonitorLive.Form do
  @moduledoc """
  Create, edit and clone monitors. The type-specific settings (an embed) are
  rendered with `inputs_for` from `Sentinelix.Monitoring.Settings.fields_for/1`
  and re-rendered when the type changes.

  Cloning (`:clone`) creates a new monitor from a form prefilled by
  `Sentinelix.Monitoring.clone_monitor/1` and the source's notification
  channels. Secrets are not copied: the secrets the source has must be
  entered again before the clone can be saved.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents

  alias Sentinelix.Checks.Postgres.Expectation
  alias Sentinelix.Monitoring
  alias Sentinelix.Monitoring.{Labels, Monitor, Settings}
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
            <%= case @live_action do %>
              <% :new -> %>
                Choose what to monitor and how often to check it.
              <% :clone -> %>
                A copy of {@source.name}. Maintenance windows and status pages are not copied.
              <% :edit -> %>
                {@monitor.name}
            <% end %>
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
              <div :for={{title, fields} <- settings_groups(@type)} id={group_id(title)}>
                <h3 :if={title} class="mt-2 mb-1 text-sm font-semibold text-base-content/70">
                  {title}
                </h3>
                <div class="grid gap-x-4 sm:grid-cols-2">
                  <%= for name <- fields, visible?(name, settings) do %>
                    <.secret_field
                      :if={name in @secret_fields}
                      name={name}
                      stored={@stored_secrets[to_string(name)]}
                      value={@params["secrets"][to_string(name)]}
                      reenter={@type == @monitor.type and to_string(name) in @reenter_secrets}
                      errors={@secret_errors[to_string(name)] || []}
                    />
                    <.settings_field
                      :if={name not in @secret_fields}
                      name={name}
                      field={settings[name]}
                      type={@type}
                    />
                  <% end %>
                </div>
              </div>
            </.inputs_for>
          </section>

          <section
            id="monitor-labels"
            class="rounded-box border border-base-300 bg-base-100 p-4 sm:p-6"
          >
            <h2 class="font-semibold">Labels</h2>
            <p class="mt-1 mb-3 text-xs text-base-content/60">
              Key/value pairs like env=prod or site=oslo to group and filter monitors.
              The value is optional.
            </p>
            <div
              :for={{row, index} <- Enum.with_index(@label_rows)}
              id={"label-row-#{index}"}
              class="mb-2 flex items-center gap-2"
            >
              <input
                type="text"
                id={"monitor_labels_#{index}_key"}
                name={"monitor[labels][#{index}][key]"}
                value={row["key"]}
                placeholder="key"
                list="label-keys"
                aria-label="Label key"
                autocomplete="off"
                phx-debounce="300"
                class={[
                  "input input-sm min-w-0 flex-1 font-mono",
                  @label_errors != [] && "input-error"
                ]}
              />
              <span class="text-base-content/50">=</span>
              <input
                type="text"
                id={"monitor_labels_#{index}_value"}
                name={"monitor[labels][#{index}][value]"}
                value={row["value"]}
                placeholder="value"
                list={"label-values-#{index}"}
                aria-label="Label value"
                autocomplete="off"
                phx-debounce="300"
                class={[
                  "input input-sm min-w-0 flex-1 font-mono",
                  @label_errors != [] && "input-error"
                ]}
              />
              <datalist id={"label-values-#{index}"}>
                <option :for={value <- label_value_options(@label_values, row)} value={value} />
              </datalist>
              <button
                type="button"
                id={"remove-label-#{index}"}
                phx-click="remove_label"
                phx-value-index={index}
                class="btn btn-ghost btn-sm btn-square"
                title="Remove label"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
            <datalist id="label-keys">
              <option :for={key <- @label_values |> Map.keys() |> Enum.sort()} value={key} />
            </datalist>
            <p :for={msg <- @label_errors} class="mb-2 flex items-center gap-2 text-sm text-error">
              <.icon name="hero-exclamation-circle" class="size-5" /> {msg}
            </p>
            <button type="button" id="add-label" phx-click="add_label" class="btn btn-ghost btn-sm">
              <.icon name="hero-plus" class="size-4" /> Add label
            </button>
          </section>

          <section class="rounded-box border border-base-300 bg-base-100 p-4 sm:p-6">
            <h2 class="mb-3 font-semibold">Description</h2>
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
              {if @live_action == :edit, do: "Save changes", else: "Create monitor"}
            </.button>
            <.link navigate={@return_to} class="btn btn-ghost">Cancel</.link>
          </div>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  # Settings fields per type, in groups of {title, fields}. Secret fields
  # (see Monitor.secret_fields/1) are rendered by secret_field/1.
  @settings_groups %{
    postgres: [
      {"Connection", [:host, :port, :database, :username, :password, :ssl_mode, :ssl_ca_cert]},
      {"Query", [:query, :expected_value, :comparison, :expected_rows, :rows_comparison]},
      {"Replication",
       [
         :replication_check,
         :min_standbys,
         :lag_warn_seconds,
         :lag_critical_seconds,
         :lag_warn_bytes,
         :lag_critical_bytes
       ]}
    ]
  }

  @doc false
  def settings_groups(type) do
    Map.get_lazy(@settings_groups, type, fn -> [{nil, Settings.fields_for(type)}] end)
  end

  defp group_id(nil), do: nil
  defp group_id(title), do: "settings-group-#{String.downcase(title)}"

  # Fields that only matter for some values of other fields.
  defp visible?(:ssl_ca_cert, settings), do: settings[:ssl_mode].value == "verify-full"
  defp visible?(:min_standbys, settings), do: settings[:replication_check].value == "primary"

  defp visible?(name, settings)
       when name in [
              :lag_warn_seconds,
              :lag_critical_seconds,
              :lag_warn_bytes,
              :lag_critical_bytes
            ],
       do: settings[:replication_check].value in ["primary", "standby"]

  defp visible?(_name, _settings), do: true

  attr :name, :atom, required: true
  attr :stored, :boolean, default: false, doc: "whether a value is stored"
  attr :value, :string, default: nil, doc: "the value entered in this form"
  attr :reenter, :boolean, default: false, doc: "whether it must be entered again (clones)"
  attr :errors, :list, default: []

  # Secrets are write-only: the stored value is never rendered, a blank
  # input keeps it (see Monitor). Only what was typed in this form is
  # rendered back, so it survives re-renders on validation.
  defp secret_field(assigns) do
    ~H"""
    <div>
      <.input
        type="password"
        id={"monitor_secrets_#{@name}"}
        name={"monitor[secrets][#{@name}]"}
        value={@value}
        label={Phoenix.Naming.humanize(@name)}
        placeholder={
          cond do
            @stored -> "•••••••• (unchanged)"
            @reenter -> "Enter it again"
            true -> "Not set"
          end
        }
        autocomplete="new-password"
        phx-debounce="300"
        errors={@errors}
      />
      <p
        :if={@reenter}
        id={"monitor_secrets_reenter_#{@name}"}
        class="-mt-1 mb-2 flex items-center gap-1 text-xs text-warning"
      >
        <.icon name="hero-key-micro" class="size-3" />
        Not copied from the source monitor: enter the {String.downcase(Phoenix.Naming.humanize(@name))} again.
      </p>
      <label :if={@stored} class="-mt-1 mb-2 flex items-center gap-2 text-xs text-base-content/60">
        <input
          type="checkbox"
          id={"monitor_secrets_clear_#{@name}"}
          name={"monitor[secrets][clear_#{@name}]"}
          value="true"
          class="checkbox checkbox-xs"
        /> Remove the stored {String.downcase(Phoenix.Naming.humanize(@name))}
      </label>
    </div>
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

  defp settings_field(%{name: :json_path} = assigns) do
    ~H"""
    <div>
      <.input
        field={@field}
        type="text"
        label="JSON path (optional)"
        placeholder="data.items.0.status"
        phx-debounce="300"
      />
      <p class="-mt-1 mb-2 text-xs text-base-content/60">
        When set, the value at this path of a JSON response must equal the keyword.
      </p>
    </div>
    """
  end

  defp settings_field(%{name: :push_grace_seconds} = assigns) do
    ~H"""
    <div>
      <.input field={@field} type="number" label="Grace period (seconds)" min="0" max="86400" />
      <p class="-mt-1 mb-2 text-xs text-base-content/60">
        Extra time after the interval before a missing push marks the monitor down.
      </p>
    </div>
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
      placeholder={if @type == :postgres, do: "0", else: "192.0.2.1"}
      phx-debounce="300"
    />
    """
  end

  defp settings_field(%{name: :database} = assigns) do
    ~H"""
    <.input field={@field} type="text" label="Database" placeholder="app" phx-debounce="300" />
    """
  end

  defp settings_field(%{name: :username} = assigns) do
    ~H"""
    <.input
      field={@field}
      type="text"
      label="Username"
      placeholder="sentinelix_monitor"
      autocomplete="off"
      phx-debounce="300"
    />
    """
  end

  defp settings_field(%{name: :ssl_mode} = assigns) do
    ~H"""
    <.input
      field={@field}
      type="select"
      label="SSL"
      options={[
        {"Require (certificate not verified)", "require"},
        {"Verify certificate and hostname", "verify-full"},
        {"Disable", "disable"}
      ]}
    />
    """
  end

  defp settings_field(%{name: :ssl_ca_cert} = assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.input
        field={@field}
        type="textarea"
        label="CA certificate (optional)"
        rows="3"
        placeholder="-----BEGIN CERTIFICATE-----"
        class="w-full textarea font-mono text-xs"
        phx-debounce="300"
      />
      <p class="-mt-1 mb-2 text-xs text-base-content/60">
        PEM encoded. Empty: the system's trusted CAs.
      </p>
    </div>
    """
  end

  defp settings_field(%{name: :query} = assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.input
        field={@field}
        type="textarea"
        label="Query"
        rows="3"
        class="w-full textarea font-mono text-sm"
        phx-debounce="300"
      />
      <p class="-mt-1 mb-2 text-xs text-base-content/60">
        A single statement, run in a read-only transaction.
        The expected value is compared with the first column of the first row.
      </p>
    </div>
    """
  end

  defp settings_field(%{name: :comparison} = assigns) do
    ~H"""
    <.input
      field={@field}
      type="select"
      label="Comparison"
      options={Enum.map(Expectation.comparisons(), &{comparison_label(&1), &1})}
    />
    """
  end

  defp settings_field(%{name: :expected_rows} = assigns) do
    ~H"""
    <.input field={@field} type="number" label="Expected rows (optional)" min="0" />
    """
  end

  defp settings_field(%{name: :rows_comparison} = assigns) do
    ~H"""
    <.input
      field={@field}
      type="select"
      label="Rows comparison"
      options={Enum.map(Expectation.rows_comparisons(), &{comparison_label(&1), &1})}
    />
    """
  end

  defp settings_field(%{name: :replication_check} = assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.input
        field={@field}
        type="select"
        label="Check replication"
        options={[
          {"No", "none"},
          {"Primary: standbys are streaming", "primary"},
          {"Standby: streaming from the primary", "standby"}
        ]}
      />
      <p class="-mt-1 mb-2 text-xs text-base-content/60">
        Also asserts the server's role (down after a failover). Needs the pg_monitor role.
      </p>
    </div>
    """
  end

  defp settings_field(%{name: :min_standbys} = assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.input field={@field} type="number" label="Minimum streaming standbys" min="0" />
    </div>
    """
  end

  defp settings_field(%{name: name} = assigns)
       when name in [
              :lag_warn_seconds,
              :lag_critical_seconds,
              :lag_warn_bytes,
              :lag_critical_bytes
            ] do
    ~H"""
    <.input field={@field} type="number" label={threshold_label(@name)} min="1" />
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

  defp comparison_label("equals"), do: "equals"
  defp comparison_label("not_equals"), do: "does not equal"
  defp comparison_label("contains"), do: "contains"
  defp comparison_label("regex"), do: "matches regular expression"
  defp comparison_label(operator), do: operator

  defp threshold_label(:lag_warn_seconds), do: "Warn at lag (seconds, optional)"
  defp threshold_label(:lag_critical_seconds), do: "Down at lag (seconds, optional)"
  defp threshold_label(:lag_warn_bytes), do: "Warn at lag (bytes, optional)"
  defp threshold_label(:lag_critical_bytes), do: "Down at lag (bytes, optional)"

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

  defp type_help(:postgres),
    do: "Logs in to a PostgreSQL server, runs a query and optionally checks replication."

  defp type_help(:push),
    do: "Passive monitor: your service calls the push URL; it goes down when the pushes stop."

  defp type_help(_type), do: nil

  @impl true
  def mount(params, _session, socket) do
    socket =
      assign(socket,
        channels: Notifications.list_channels(),
        label_values: Monitoring.list_label_values(),
        source: nil,
        reenter_secrets: []
      )

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

  defp apply_action(socket, :clone, %{"id" => id}) do
    case parse_id(id) && Monitoring.get_monitor(parse_id(id)) do
      nil ->
        socket
        |> put_flash(:error, "Monitor not found.")
        |> push_navigate(to: ~p"/monitors")

      source ->
        monitor = Monitoring.clone_monitor(source)

        socket
        |> assign(
          page_title: "Clone monitor",
          monitor: monitor,
          source: source,
          return_to: ~p"/monitors/#{source}",
          reenter_secrets: for({key, value} <- source.secrets || %{}, value, do: key)
        )
        |> assign(channel_ids: Notifications.monitor_channel_ids(source))
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

  def handle_event("add_label", _params, socket) do
    update_label_rows(socket, &(&1 ++ [%{"key" => "", "value" => ""}]))
  end

  def handle_event("remove_label", %{"index" => index}, socket) do
    case Integer.parse(index) do
      {index, ""} -> update_label_rows(socket, &List.delete_at(&1, index))
      _ -> {:noreply, socket}
    end
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

  # A clone is created like a new monitor (from the params only, nothing of
  # the source is kept by the changeset), once the secrets to re-enter are.
  defp save(socket, action, params) when action in [:new, :clone] do
    with {:ok, params} <- reentered_secrets(socket, params),
         {:ok, monitor} <- Monitoring.create_monitor(params) do
      :ok = Notifications.put_monitor_channels(monitor, socket.assigns.channel_ids)

      {:noreply,
       socket
       |> put_flash(:info, "Monitor created.")
       |> push_navigate(to: ~p"/monitors/#{monitor}")}
    else
      {:error, changeset} -> {:noreply, assign_form(socket, changeset, params)}
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

  defp reentered_secrets(socket, params) do
    changeset = Monitoring.change_monitor(socket.assigns.monitor, params)

    case missing_secrets(socket.assigns, Ecto.Changeset.get_field(changeset, :type), params) do
      [] -> {:ok, params}
      _missing -> {:error, %{changeset | action: :insert}}
    end
  end

  # The secrets of a clone's source that haven't been entered again. They
  # only apply while the type is the source's.
  defp missing_secrets(%{reenter_secrets: keys, monitor: monitor}, type, params) do
    entered = if is_map(params["secrets"]), do: params["secrets"], else: %{}

    if type == monitor.type,
      do: Enum.reject(keys, &(is_binary(entered[&1]) and entered[&1] != "")),
      else: []
  end

  # Errors once the form has been validated, but not for an input that
  # hasn't been used yet (LiveView sends `_unused_<name>` for those).
  defp secret_errors(socket, changeset, type, params) do
    if changeset.action do
      socket.assigns
      |> missing_secrets(type, params)
      |> Enum.reject(&Map.has_key?(params["secrets"] || %{}, "_unused_" <> &1))
      |> Map.new(&{&1, ["can't be blank"]})
    else
      %{}
    end
  end

  defp update_label_rows(socket, fun) do
    params = Map.put(socket.assigns.params, "labels", fun.(socket.assigns.label_rows))
    changeset = Monitoring.change_monitor(socket.assigns.monitor, params)
    # Keep showing errors once the form has been validated.
    changeset = %{changeset | action: socket.assigns.form.source.action}
    {:noreply, assign_form(socket, changeset, params)}
  end

  # The label editor's rows: as entered (blank rows too), or the labels of
  # the monitor before anything was entered.
  defp label_rows(%{"labels" => rows}, _changeset) when is_list(rows), do: rows

  defp label_rows(_params, changeset) do
    changeset
    |> Ecto.Changeset.get_field(:labels)
    |> Labels.to_list()
    |> Enum.map(fn {key, value} -> %{"key" => key, "value" => value} end)
  end

  # Autocompletion of a row's value: the values in use for its key.
  defp label_value_options(label_values, row) do
    key = (row["key"] || "") |> String.trim() |> String.downcase()
    label_values |> Map.get(key, []) |> Enum.reject(&(&1 == ""))
  end

  defp assign_form(socket, changeset, params) do
    type = Ecto.Changeset.get_field(changeset, :type)
    monitor = socket.assigns.monitor
    # Stored secrets only apply while the type is unchanged.
    stored = if monitor.type == type, do: monitor.secrets || %{}, else: %{}
    form = to_form(changeset)

    assign(socket,
      form: form,
      type: type,
      params: params,
      label_rows: label_rows(params, changeset),
      label_errors: Enum.map(form[:labels].errors, &translate_error/1),
      secret_fields: Enum.map(Monitor.secret_fields(type), &String.to_existing_atom/1),
      stored_secrets: Map.new(stored, fn {key, value} -> {key, value != nil} end),
      secret_errors: secret_errors(socket, changeset, type, params)
    )
  end

  ## Params

  # The form uses plain text inputs for list and map fields; turn them into
  # the shapes the changeset casts. The label editor's rows arrive as an
  # index => row map, and not at all when there are none (no labels).
  @doc false
  def normalize_params(params) do
    params
    |> Map.update("labels", [], &label_params/1)
    |> update_present("settings", fn settings ->
      settings
      |> update_present("accepted_status_codes", &split_list(&1, ~r/[,\s]+/))
      |> update_present("headers", &parse_headers/1)
    end)
  end

  defp label_params(rows) when is_map(rows) do
    rows
    |> Enum.flat_map(fn {index, row} ->
      case Integer.parse(index) do
        {index, ""} when is_map(row) -> [{index, Map.take(row, ["key", "value"])}]
        _ -> []
      end
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defp label_params(rows), do: rows

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
