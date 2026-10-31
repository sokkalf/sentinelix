defmodule SentinelixWeb.SavedViewComponents do
  @moduledoc """
  Pieces of saved views (`Sentinelix.SavedViews`) shared by the dashboard,
  the saved views page and the sidebar: the name/visibility/groups fields
  of their forms and how a view's visibility is shown.
  """

  use SentinelixWeb, :html

  alias Sentinelix.Accounts.User
  alias Sentinelix.SavedViews.SavedView

  @doc """
  The name, visibility and groups fields of a saved view form (for a
  `Sentinelix.SavedViews.change_view/3` changeset). `groups` are the
  groups the user can choose (their own); the view's current groups are
  offered too. Without any, the groups visibility isn't offered.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :groups, :list, required: true

  def saved_view_fields(assigns) do
    groups = Enum.sort(Enum.uniq(assigns.groups ++ (assigns.form[:groups].value || [])))
    visibility = assigns.form[:visibility].value |> to_string()

    assigns =
      assign(assigns,
        groups: groups,
        visibility: visibility,
        options:
          [{"Personal: only you", "personal"}, {"Shared: all users", "shared"}] ++
            if(groups != [], do: [{"Groups: members of the groups chosen", "groups"}], else: [])
      )

    ~H"""
    <.input field={@form[:name]} label="Name" placeholder="Production overview" maxlength="80" />
    <.input field={@form[:visibility]} type="select" label="Visible to" options={@options} />
    <fieldset :if={@visibility == "groups"} id={@form[:groups].id} class="fieldset mb-2">
      <legend class="label mb-1">Groups</legend>
      <input type="hidden" name={@form[:groups].name <> "[]"} value="" />
      <label :for={group <- @groups} class="label">
        <input
          type="checkbox"
          name={@form[:groups].name <> "[]"}
          value={group}
          checked={group in (@form[:groups].value || [])}
          class="checkbox checkbox-sm"
        />
        <span class="font-mono text-sm">{group}</span>
      </label>
      <p
        :for={{message, _opts} <- @form[:groups].errors}
        :if={Phoenix.Component.used_input?(@form[:groups])}
        class="mt-1 flex items-center gap-2 text-sm text-error"
      >
        <.icon name="hero-exclamation-circle" class="size-5" />
        {message}
      </p>
    </fieldset>
    """
  end

  @doc "A short description of who sees a view."
  @spec visibility_label(SavedView.t()) :: String.t()
  def visibility_label(%SavedView{visibility: :personal}), do: "Personal"
  def visibility_label(%SavedView{visibility: :shared}), do: "Shared"

  def visibility_label(%SavedView{visibility: :groups, groups: groups}),
    do: Enum.join(groups, ", ")

  @doc "The icon of a view's visibility."
  @spec visibility_icon(SavedView.t()) :: String.t()
  def visibility_icon(%SavedView{visibility: :personal}), do: "hero-lock-closed"
  def visibility_icon(%SavedView{visibility: :shared}), do: "hero-globe-alt"
  def visibility_icon(%SavedView{visibility: :groups}), do: "hero-user-group"

  @doc "A badge with a view's visibility."
  attr :view, SavedView, required: true
  attr :rest, :global

  def visibility_badge(assigns) do
    ~H"""
    <span class="badge badge-sm gap-1" title={visibility_title(@view)} {@rest}>
      <.icon name={visibility_icon(@view)} class="size-3" />
      {visibility_label(@view)}
    </span>
    """
  end

  defp visibility_title(%SavedView{visibility: :personal}), do: "Only you see this view"
  defp visibility_title(%SavedView{visibility: :shared}), do: "All users see this view"

  defp visibility_title(%SavedView{visibility: :groups}),
    do: "Members of these groups see this view"

  @doc "Who owns a view, from the point of view of `scope`: \"you\" or their name."
  @spec owner_name(SavedView.t(), Sentinelix.Accounts.Scope.t()) :: String.t()
  def owner_name(%SavedView{owner_id: id}, %{user: %User{id: id}}), do: "you"
  def owner_name(%SavedView{owner: %User{} = owner}, _scope), do: User.display_name(owner)
  def owner_name(%SavedView{}, _scope), do: "another user"
end
