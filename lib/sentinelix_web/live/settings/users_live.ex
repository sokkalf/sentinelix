defmodule SentinelixWeb.Settings.UsersLive do
  @moduledoc """
  Settings → Users & sessions: lists the users (OIDC and local) with their
  last login and active sessions, and lets an admin revoke a user's
  sessions or delete the user.

  OIDC allow-lists are only checked at login, so revoking the sessions is
  how a user is cut off right away.
  """

  use SentinelixWeb, :live_view

  import SentinelixWeb.MonitorComponents, only: [local_time: 1]

  alias Sentinelix.Accounts
  alias Sentinelix.Accounts.User
  alias SentinelixWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:users}>
      <.header>
        Users & sessions
        <:subtitle>
          Users are created on their first OIDC login or as local break-glass accounts.
        </:subtitle>
      </.header>

      <div class="rounded-box border border-base-300 bg-base-100">
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>User</th>
                <th>Type</th>
                <th class="hidden md:table-cell">Last login</th>
                <th>Sessions</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody id="users" phx-update="stream">
              <tr :for={{dom_id, row} <- @streams.users} id={dom_id}>
                <td class="max-w-64">
                  <div class="flex items-center gap-2">
                    <span class="truncate font-medium">{User.display_name(row.user)}</span>
                    <span
                      :if={row.user.id == @current_scope.user.id}
                      class="badge badge-primary badge-xs"
                    >
                      You
                    </span>
                  </div>
                  <div :if={row.user.email} class="truncate text-xs text-base-content/60">
                    {row.user.email}
                  </div>
                </td>
                <td>
                  <span :if={User.local?(row.user)} class="badge badge-warning badge-soft badge-sm">Local</span>
                  <span
                    :if={!User.local?(row.user)}
                    class="badge badge-info badge-soft badge-sm"
                    title={row.user.oidc_issuer}
                  >
                    OIDC
                  </span>
                </td>
                <td class="hidden whitespace-nowrap md:table-cell">
                  <.local_time id={"#{dom_id}-last-login"} at={row.user.last_login_at} />
                </td>
                <td class="tabular-nums">{row.sessions}</td>
                <td>
                  <div :if={row.user.id != @current_scope.user.id} class="flex justify-end gap-1">
                    <button
                      type="button"
                      id={"revoke-#{row.user.id}"}
                      phx-click="revoke"
                      phx-value-id={row.user.id}
                      data-confirm={"Log #{User.display_name(row.user)} out everywhere?"}
                      class="btn btn-ghost btn-xs"
                      disabled={row.sessions == 0}
                    >
                      <.icon name="hero-no-symbol" class="size-4" /> Revoke sessions
                    </button>
                    <button
                      type="button"
                      id={"delete-#{row.user.id}"}
                      phx-click="delete"
                      phx-value-id={row.user.id}
                      data-confirm={"Delete #{User.display_name(row.user)} and log them out?"}
                      class="btn btn-ghost btn-xs text-error"
                    >
                      <.icon name="hero-trash" class="size-4" /> Delete
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <p class="text-xs text-base-content/60">
        Deleting an OIDC user doesn't block them: they are provisioned again on their next login
        if the identity provider and the allow-lists still let them in. Remove their access there
        and revoke their sessions here. The bootstrap admin is recreated on start while <code>ADMIN_EMAIL</code>/<code>ADMIN_PASSWORD</code>
        are set.
      </p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    rows =
      Enum.map(Accounts.list_users_with_session_counts(), fn {user, sessions} ->
        row(user, sessions)
      end)

    {:ok,
     socket
     |> assign(page_title: "Users & sessions")
     |> stream_configure(:users, dom_id: &"user-#{&1.id}")
     |> stream(:users, rows)}
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    with_other_user(socket, id, fn user ->
      user |> Accounts.delete_all_user_session_tokens() |> UserAuth.disconnect_sessions()

      socket
      |> put_flash(:info, "Revoked all sessions of #{User.display_name(user)}.")
      |> stream_insert(:users, row(user, 0))
    end)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with_other_user(socket, id, fn user ->
      case Accounts.delete_user(user) do
        {:ok, user, tokens} ->
          UserAuth.disconnect_sessions(tokens)

          socket
          |> put_flash(:info, "Deleted #{User.display_name(user)}.")
          |> stream_delete(:users, row(user, 0))

        {:error, _changeset} ->
          put_flash(socket, :error, "Could not delete the user.")
      end
    end)
  end

  defp with_other_user(socket, id, fun) do
    current_id = socket.assigns.current_scope.user.id

    case Integer.parse(to_string(id)) do
      {^current_id, ""} ->
        {:noreply, put_flash(socket, :error, "You can't do that to your own account.")}

      {id, ""} ->
        case Accounts.get_user(id) do
          nil -> {:noreply, put_flash(socket, :error, "User not found.")}
          user -> {:noreply, fun.(user)}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "User not found.")}
    end
  end

  defp row(user, sessions), do: %{id: user.id, user: user, sessions: sessions}
end
