defmodule SentinelixWeb.Live.NotificationSettings do
  @moduledoc """
  Settings page for notification channels (`/settings/notifications`):
  list, create, edit, delete and test channels, and choose the monitors a
  channel is attached to.

  Secret config fields (tokens, webhook URLs with embedded tokens) are never
  rendered back; leaving them blank on edit keeps the stored value.
  """

  use SentinelixWeb, :live_view

  alias Sentinelix.{Monitoring, Notifications}
  alias Sentinelix.Notifications.{Channel, Delivery, Provider}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:notifications}>
      <%= if @live_action == :index do %>
        <.header>
          Notification channels
          <:subtitle>Where alerts go when a monitor goes down or recovers.</:subtitle>
          <:actions>
            <.button id="new-channel" variant="primary" patch={~p"/settings/notifications/new"}>
              <.icon name="hero-plus" class="size-4" /> New channel
            </.button>
          </:actions>
        </.header>

        <p :if={@channels == []} id="no-channels" class="text-sm opacity-70">
          No notification channels yet.
        </p>

        <.table :if={@channels != []} id="channels" rows={@channels} row_id={&"channel-#{&1.id}"}>
          <:col :let={channel} label="Name">
            <span class="font-semibold">{channel.name}</span>
            <span :if={channel.default} class="badge badge-sm badge-info ml-1">default</span>
          </:col>
          <:col :let={channel} label="Type">{provider_label(channel.type)}</:col>
          <:col :let={channel} label="Details">
            <span class="text-sm opacity-70">{summary(channel)}</span>
          </:col>
          <:col :let={channel} label="Monitors">{Map.get(@monitor_counts, channel.id, 0)}</:col>
          <:col :let={channel} label="Status">
            <button
              id={"toggle-channel-#{channel.id}"}
              phx-click="toggle"
              phx-value-id={channel.id}
              class={["badge cursor-pointer", channel.enabled && "badge-success"]}
              title={if channel.enabled, do: "Click to disable", else: "Click to enable"}
            >
              {if channel.enabled, do: "enabled", else: "disabled"}
            </button>
          </:col>
          <:action :let={channel}>
            <button
              id={"test-channel-#{channel.id}"}
              phx-click="test"
              phx-value-id={channel.id}
              class="link link-hover"
              disabled={@testing}
            >
              Test
            </button>
            <.link patch={~p"/settings/notifications/#{channel.id}/edit"} class="link link-hover">
              Edit
            </.link>
            <button
              id={"delete-channel-#{channel.id}"}
              phx-click="delete"
              phx-value-id={channel.id}
              data-confirm={"Delete the channel \"#{channel.name}\"?"}
              class="link link-hover text-error"
            >
              Delete
            </button>
          </:action>
        </.table>
      <% else %>
        <.header>
          {if @live_action == :new, do: "New notification channel", else: "Edit #{@channel.name}"}
          <:actions>
            <.button patch={~p"/settings/notifications"}>Back</.button>
          </:actions>
        </.header>

        <.form
          for={@form}
          id="channel-form"
          phx-change="validate"
          phx-submit="save"
          class="max-w-2xl space-y-2"
        >
          <.input field={@form[:name]} label="Name" placeholder="Ops team" />
          <.input
            field={@form[:type]}
            type="select"
            label="Type"
            prompt="Choose a provider"
            options={provider_options()}
          />

          <div :if={@provider} id="provider-fields" class="space-y-2">
            <.config_input
              :for={field <- @provider.fields()}
              field={field}
              value={config_value(assigns, field)}
              stored?={stored_secret?(@channel, @form, field)}
              errors={config_errors(@form, @config_params, field)}
            />
          </div>

          <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
          <.input
            field={@form[:default]}
            type="checkbox"
            label="Default: attach to new monitors automatically"
          />

          <fieldset id="channel-monitors" class="fieldset">
            <legend class="fieldset-legend">Monitors</legend>
            <input type="hidden" name="monitor_ids[]" value="" />
            <p :if={@monitors == []} class="text-sm opacity-70">No monitors yet.</p>
            <label :for={monitor <- @monitors} class="label">
              <input
                type="checkbox"
                name="monitor_ids[]"
                value={monitor.id}
                checked={monitor.id in @monitor_ids}
                class="checkbox checkbox-sm"
              />
              {monitor.name}
            </label>
          </fieldset>

          <div class="flex gap-2 pt-2">
            <.button variant="primary" name="action" value="save" phx-disable-with="Saving...">
              Save
            </.button>
            <.button
              :if={@provider}
              id="send-test"
              name="action"
              value="test"
              disabled={@testing}
            >
              Send test notification
            </.button>
          </div>
        </.form>
      <% end %>
    </Layouts.app>
    """
  end

  attr :field, :map, required: true
  attr :value, :string, default: nil
  attr :stored?, :boolean, default: false
  attr :errors, :list, default: []

  defp config_input(assigns) do
    ~H"""
    <div>
      <.input
        id={"channel_config_#{@field.key}"}
        name={"channel[config][#{@field.key}]"}
        type={input_type(@field)}
        label={@field.label <> if(@field[:required], do: "", else: " (optional)")}
        value={@value}
        options={@field[:options] || []}
        placeholder={placeholder(@field, @stored?)}
        autocomplete={if @field[:secret], do: "off"}
        errors={@errors}
      />
      <p :if={@field[:help]} class="-mt-1 mb-2 text-xs opacity-70">{@field.help}</p>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Notifications.subscribe_channels()
    {:ok, assign(socket, testing: false)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: "Notifications", channel: nil, form: nil)
    |> load_channels()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(page_title: "New notification channel", channel: %Channel{}, monitor_ids: [])
    |> assign(monitors: Monitoring.list_monitors())
    |> assign_form(Notifications.change_channel(%Channel{}), %{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         %Channel{} = channel <- Notifications.get_channel(id) do
      socket
      |> assign(page_title: "Edit #{channel.name}", channel: channel)
      |> assign(monitors: Monitoring.list_monitors())
      |> assign(monitor_ids: Notifications.channel_monitor_ids(channel))
      |> assign_form(Notifications.change_channel(channel), %{})
    else
      _ ->
        socket
        |> put_flash(:error, "Notification channel not found")
        |> push_patch(to: ~p"/settings/notifications")
    end
  end

  defp load_channels(socket) do
    assign(socket,
      channels: Notifications.list_channels(),
      monitor_counts: Notifications.channel_monitor_counts()
    )
  end

  defp assign_form(socket, changeset, config_params) do
    type = Ecto.Changeset.get_field(changeset, :type)

    assign(socket,
      form: to_form(changeset),
      provider: type && Provider.for_type(type),
      config_params: config_params
    )
  end

  @impl true
  def handle_event("validate", params, socket) do
    channel_params = Map.get(params, "channel", %{})

    changeset =
      socket.assigns.channel
      |> Notifications.change_channel(channel_params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(monitor_ids: monitor_ids(params))
     |> assign_form(changeset, config_params(channel_params))}
  end

  def handle_event("save", %{"action" => "test"} = params, socket) do
    channel_params = Map.get(params, "channel", %{})
    changeset = Notifications.change_channel(socket.assigns.channel, channel_params)
    socket = assign(socket, monitor_ids: monitor_ids(params))

    if changeset.valid? do
      {:noreply, start_test(socket, Ecto.Changeset.apply_changes(changeset))}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Fix the errors before sending a test notification")
       |> assign_form(Map.put(changeset, :action, :validate), config_params(channel_params))}
    end
  end

  def handle_event("save", params, socket) do
    channel_params = Map.get(params, "channel", %{})
    socket = assign(socket, monitor_ids: monitor_ids(params))

    result =
      case socket.assigns.live_action do
        :new -> Notifications.create_channel(channel_params)
        :edit -> Notifications.update_channel(socket.assigns.channel, channel_params)
      end

    case result do
      {:ok, channel} ->
        :ok = Notifications.put_channel_monitors(channel, socket.assigns.monitor_ids)

        {:noreply,
         socket
         |> put_flash(:info, "Notification channel \"#{channel.name}\" saved")
         |> push_patch(to: ~p"/settings/notifications")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset, config_params(channel_params))}
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    case fetch_channel(id) do
      %Channel{} = channel -> {:noreply, start_test(socket, channel)}
      nil -> {:noreply, socket |> put_flash(:error, "Channel not found") |> load_channels()}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with %Channel{} = channel <- fetch_channel(id),
         {:ok, _channel} <- Notifications.update_channel(channel, %{enabled: !channel.enabled}) do
      {:noreply, load_channels(socket)}
    else
      _ -> {:noreply, socket |> put_flash(:error, "Could not update channel") |> load_channels()}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with %Channel{} = channel <- fetch_channel(id),
         {:ok, channel} <- Notifications.delete_channel(channel) do
      {:noreply,
       socket
       |> put_flash(:info, "Notification channel \"#{channel.name}\" deleted")
       |> load_channels()}
    else
      _ -> {:noreply, socket |> put_flash(:error, "Could not delete channel") |> load_channels()}
    end
  end

  @impl true
  def handle_async(:test_notification, {:ok, {name, :ok}}, socket) do
    {:noreply,
     socket |> assign(testing: false) |> put_flash(:info, "Test notification sent to #{name}")}
  end

  def handle_async(:test_notification, {:ok, {name, {:error, reason}}}, socket) do
    {:noreply,
     socket
     |> assign(testing: false)
     |> put_flash(
       :error,
       "Test notification to #{name} failed: #{Delivery.format_error(reason)}"
     )}
  end

  def handle_async(:test_notification, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(testing: false)
     |> put_flash(:error, "Test notification failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({event, _channel}, %{assigns: %{live_action: :index}} = socket)
      when event in [:channel_created, :channel_updated, :channel_deleted],
      do: {:noreply, load_channels(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp start_test(socket, channel) do
    socket
    |> assign(testing: true)
    |> start_async(:test_notification, fn ->
      {channel.name, Notifications.send_test_notification(channel)}
    end)
  end

  defp fetch_channel(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Notifications.get_channel(id)
      _ -> nil
    end
  end

  defp monitor_ids(params) do
    params
    |> Map.get("monitor_ids", [])
    |> List.wrap()
    |> Enum.flat_map(fn id ->
      case Integer.parse(to_string(id)) do
        {id, ""} -> [id]
        _ -> []
      end
    end)
  end

  defp config_params(%{"config" => config}) when is_map(config), do: config
  defp config_params(_params), do: %{}

  ## Rendering helpers

  defp provider_options do
    Enum.map(Provider.types(), &{provider_label(&1), &1})
  end

  defp provider_label(type), do: Provider.for_type(type).label()

  defp summary(channel) do
    channel
    |> Channel.public_config()
    |> Enum.map_join(" · ", fn {_field, value} -> value end)
  end

  defp input_type(%{type: :textarea}), do: "textarea"
  defp input_type(%{type: :password}), do: "password"
  defp input_type(%{type: :select}), do: "select"
  defp input_type(%{secret: true}), do: "password"
  defp input_type(%{type: :url}), do: "url"
  defp input_type(_field), do: "text"

  defp placeholder(%{secret: true}, true), do: "Saved – leave blank to keep"
  defp placeholder(field, _stored?), do: field[:placeholder]

  # What the user typed wins; secrets are never rendered from the stored
  # config. Non-secret fields fall back to the stored value, then the
  # field's default.
  defp config_value(%{config_params: params, channel: channel, form: form}, field) do
    cond do
      Map.has_key?(params, field.key) ->
        params[field.key]

      field[:secret] ->
        nil

      true ->
        stored = if same_type?(channel, form), do: (channel.config || %{})[field.key]
        stored || field[:default]
    end
  end

  defp stored_secret?(channel, form, field) do
    field[:secret] == true and same_type?(channel, form) and
      (channel.config || %{})[field.key] not in [nil, ""]
  end

  defp same_type?(channel, form),
    do: channel.type != nil and channel.type == Ecto.Changeset.get_field(form.source, :type)

  defp config_errors(form, params, field) do
    if form.source.action && !Map.has_key?(params, "_unused_" <> field.key) do
      form.source |> Channel.config_errors(field.key) |> Enum.map(&translate_error/1)
    else
      []
    end
  end
end
