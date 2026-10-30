defmodule Sentinelix.StatusPages.StatusPage do
  @moduledoc """
  A public status page: a shareable, unauthenticated page at
  `/status/<slug>` showing ordered groups of monitors.

  Only published pages are reachable. Monitor targets and check messages are
  hidden unless `show_details` is enabled.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sentinelix.StatusPages.Group

  @slug_format ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @max_slug_length 64

  schema "status_pages" do
    field :slug, :string
    field :title, :string
    field :description, :string
    field :footer_text, :string
    field :published, :boolean, default: false
    field :show_details, :boolean, default: false

    has_many :groups, Group, preload_order: [asc: :position, asc: :id]

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(page, attrs) do
    page
    |> cast(attrs, [:slug, :title, :description, :footer_text, :published, :show_details])
    |> update_change(:slug, &(&1 && &1 |> String.trim() |> String.downcase()))
    |> put_default_slug()
    |> validate_required([:slug, :title])
    |> validate_length(:title, max: 255)
    |> validate_length(:description, max: 5_000)
    |> validate_length(:footer_text, max: 2_000)
    |> validate_length(:slug, max: @max_slug_length)
    |> validate_format(:slug, @slug_format,
      message: "may only contain lowercase letters, digits and dashes"
    )
    |> unique_constraint(:slug)
  end

  # A page without a slug gets one derived from its title.
  defp put_default_slug(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :title)} do
      {slug, title} when slug in [nil, ""] and is_binary(title) ->
        put_change(changeset, :slug, slugify(title))

      _ ->
        changeset
    end
  end

  @doc """
  Turns a title into a slug (`"My Status!"` => `"my-status"`).
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(title) do
    title
    |> String.normalize(:nfd)
    |> String.replace(~r/[^A-Za-z0-9\s-]/u, "")
    |> String.downcase()
    |> String.split(~r/[\s-]+/, trim: true)
    |> Enum.join("-")
    |> String.slice(0, @max_slug_length)
    |> String.trim_trailing("-")
  end
end
