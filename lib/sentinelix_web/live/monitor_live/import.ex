defmodule SentinelixWeb.MonitorLive.Import do
  @moduledoc """
  Imports monitors from an uploaded YAML file (see
  `Sentinelix.Monitoring.Import`) in two steps: the upload is checked with a
  dry run, which lists what would be created and updated (and, if asked,
  the monitors missing from the file), and only "Import" writes it, in one
  transaction. The file is kept in the LiveView between the steps; the
  import checks it again, so changes made in between are taken into
  account.
  """

  use SentinelixWeb, :live_view

  alias Sentinelix.Monitoring.Import
  alias Sentinelix.Monitoring.Import.{Error, Result}

  @max_file_size 5_000_000

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:monitors}>
      <.header>
        Import monitors
        <:subtitle>
          Upload a YAML file exported from Sentinelix. Monitors are matched by name;
          nothing is written until you confirm.
        </:subtitle>
        <:actions>
          <.button navigate={~p"/monitors"}>Back to monitors</.button>
        </:actions>
      </.header>

      <form
        :if={@result == nil}
        id="import-form"
        phx-change="validate"
        phx-submit="check"
        class="space-y-4 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <.live_file_input
          upload={@uploads.file}
          class="file-input file-input-bordered w-full max-w-md"
        />
        <p :for={error <- upload_errors(@uploads.file)} class="text-sm text-error">
          {upload_error(error)}
        </p>
        <%= for entry <- @uploads.file.entries do %>
          <p :for={error <- upload_errors(@uploads.file, entry)} class="text-sm text-error">
            {upload_error(error)}
          </p>
        <% end %>
        <label class="label cursor-pointer gap-2">
          <input
            type="checkbox"
            name="report_missing"
            value="true"
            checked={@report_missing}
            class="checkbox checkbox-sm"
          />
          <span>List monitors that aren't in the file (they are left alone)</span>
        </label>
        <div>
          <.button variant="primary" id="check-import" disabled={@uploads.file.entries == []}>
            Check file
          </.button>
        </div>
      </form>

      <div
        :if={@errors != []}
        id="import-errors"
        class="mt-4 rounded-box border border-error/40 bg-error/10 p-4"
      >
        <p class="font-medium text-error">Nothing can be imported from {@filename}:</p>
        <ul class="mt-2 list-inside list-disc text-sm">
          <li :for={error <- @errors}>{Error.format(error)}</li>
        </ul>
      </div>

      <div :if={@result} id="import-preview" class="space-y-4">
        <div class="rounded-box border border-base-300 bg-base-100">
          <div class="flex flex-wrap items-center gap-3 border-b border-base-300 p-3">
            <span class="font-medium">{@filename}</span>
            <span class="badge badge-success badge-soft" id="count-create">
              {@counts.create} to create
            </span>
            <span class="badge badge-info badge-soft" id="count-update">
              {@counts.update} to update
            </span>
            <span class="badge badge-soft" id="count-unchanged">{@counts.unchanged} unchanged</span>
          </div>
          <table :if={@changed != []} class="table">
            <thead>
              <tr>
                <th>Monitor</th>
                <th>Change</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{change, index} <- Enum.with_index(@changed)} id={"change-#{index}"}>
                <td class="font-medium">{change.name}</td>
                <td>
                  <span :if={change.action == :create} class="text-success">Create</span>
                  <span :if={change.action == :update}>
                    Update <span class="text-base-content/60">{Enum.join(change.fields, ", ")}</span>
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@changed == []} class="p-4 text-base-content/60">
            Every monitor in the file is up to date.
          </p>
        </div>

        <div
          :if={@result.missing not in [nil, []]}
          id="import-missing"
          class="rounded-box border border-base-300 bg-base-100 p-4"
        >
          <p class="font-medium">Not in the file (left alone):</p>
          <p class="mt-1 text-sm text-base-content/70">{Enum.join(@result.missing, ", ")}</p>
        </div>

        <p class="text-sm text-base-content/60">
          Secrets (such as PostgreSQL passwords) aren't part of the file: updated monitors keep
          theirs, created ones have none.
        </p>

        <div class="flex gap-2">
          <.button
            :if={@changed != []}
            variant="primary"
            id="apply-import"
            phx-click="apply"
            phx-disable-with="Importing..."
          >
            Import
          </.button>
          <.button id="reset-import" phx-click="reset">Choose another file</.button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Import monitors", report_missing: false)
     |> reset()
     # Any file: MIME doesn't know YAML, and the import rejects what isn't.
     |> allow_upload(:file,
       accept: :any,
       max_entries: 1,
       max_file_size: @max_file_size
     )}
  end

  defp reset(socket) do
    assign(socket, yaml: nil, filename: nil, result: nil, errors: [], changed: [], counts: nil)
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, report_missing: params["report_missing"] == "true")}
  end

  def handle_event("check", params, socket) do
    socket = assign(socket, report_missing: params["report_missing"] == "true")

    case consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
           {:ok, {entry.client_name, File.read!(path)}}
         end) do
      [{filename, yaml}] ->
        {:noreply,
         socket
         |> assign(yaml: yaml, filename: filename)
         |> run_import(dry_run: true)}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event("apply", _params, %{assigns: %{yaml: yaml}} = socket) when is_binary(yaml) do
    case Import.run(yaml, import_opts(socket, dry_run: false)) do
      {:ok, result} ->
        counts = Result.counts(result)

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Imported #{socket.assigns.filename}: #{counts.create} created, " <>
             "#{counts.update} updated, #{counts.unchanged} unchanged."
         )
         |> push_navigate(to: ~p"/monitors")}

      {:error, errors} ->
        {:noreply, assign(socket, result: nil, errors: errors)}
    end
  end

  def handle_event("apply", _params, socket), do: {:noreply, socket}

  def handle_event("reset", _params, socket), do: {:noreply, reset(socket)}

  defp run_import(socket, opts) do
    case Import.run(socket.assigns.yaml, import_opts(socket, opts)) do
      {:ok, result} ->
        assign(socket,
          result: result,
          errors: [],
          counts: Result.counts(result),
          changed: Enum.reject(result.changes, &(&1.action == :unchanged))
        )

      {:error, errors} ->
        assign(socket, result: nil, errors: errors)
    end
  end

  defp import_opts(socket, opts) do
    Keyword.put(opts, :missing, if(socket.assigns.report_missing, do: :report, else: :ignore))
  end

  defp upload_error(:too_large), do: "The file is larger than 5 MB."
  defp upload_error(:too_many_files), do: "Choose a single file."
  defp upload_error(error), do: "Upload failed: #{error}"
end
