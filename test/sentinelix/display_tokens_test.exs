defmodule Sentinelix.DisplayTokensTest do
  use Sentinelix.DataCase, async: true

  import Sentinelix.AccountsFixtures
  import Sentinelix.DisplayTokensFixtures
  import Sentinelix.SavedViewsFixtures

  alias Sentinelix.Accounts
  alias Sentinelix.Accounts.Scope
  alias Sentinelix.DisplayTokens
  alias Sentinelix.DisplayTokens.DisplayToken
  alias Sentinelix.Repo
  alias Sentinelix.SavedViews

  defp scope(groups \\ []), do: oidc_user_fixture(%{groups: groups}) |> Scope.for_user()

  describe "create_token/2" do
    test "returns the token once and stores only its hash" do
      scope = scope()
      first = saved_view_fixture(scope, name: "First")
      second = saved_view_fixture(scope, name: "Second")

      assert {:ok, token, display_token} =
               DisplayTokens.create_token(scope, %{
                 "name" => " Office TV ",
                 "view_ids" => ["", to_string(second.id), to_string(first.id)],
                 "rotate_seconds" => "30"
               })

      assert byte_size(token) == 43
      assert display_token.name == "Office TV"
      assert display_token.rotate_seconds == 30
      assert display_token.user_id == scope.user.id
      assert display_token.expires_at == nil
      assert display_token.token_hash == :crypto.hash(:sha256, token)
      # In the order given.
      assert Enum.map(display_token.token_views, & &1.saved_view_id) == [second.id, first.id]

      stored = Repo.get!(DisplayToken, display_token.id)
      refute stored.token_hash == token
      refute inspect(stored) =~ token

      assert {:ok, %DisplayToken{id: id}} = DisplayTokens.verify_token(token)
      assert id == display_token.id
    end

    test "creates different tokens every time" do
      scope = scope()
      view = saved_view_fixture(scope)
      {first, _} = display_token_fixture(scope, [view])
      {second, _} = display_token_fixture(scope, [view])
      refute first == second
    end

    test "needs views the user sees" do
      scope = scope()
      other = scope()
      personal = saved_view_fixture(other, visibility: :personal)
      shared = saved_view_fixture(other, visibility: :shared)

      assert {:error, changeset} = DisplayTokens.create_token(scope, %{view_ids: []})
      assert "pick at least one view" in errors_on(changeset).view_ids

      assert {:error, changeset} = DisplayTokens.create_token(scope, %{view_ids: [personal.id]})
      assert "you can only choose views you can see" in errors_on(changeset).view_ids

      assert {:ok, _token, _display_token} =
               DisplayTokens.create_token(scope, %{view_ids: [shared.id]})
    end

    test "validates the rotation and expiry" do
      scope = scope()
      view = saved_view_fixture(scope)

      assert {:error, changeset} =
               DisplayTokens.create_token(scope, %{
                 view_ids: [view.id],
                 rotate_seconds: 1,
                 expires_in_days: 3
               })

      assert errors_on(changeset).rotate_seconds != []
      assert errors_on(changeset).expires_in_days != []

      {:ok, _token, display_token} =
        DisplayTokens.create_token(scope, %{view_ids: [view.id], expires_in_days: "30"})

      assert_in_delta DateTime.diff(display_token.expires_at, DateTime.utc_now(), :day), 30, 1
    end
  end

  describe "verify_token/1" do
    test "is :error for unknown, malformed and expired tokens alike" do
      scope = scope()
      view = saved_view_fixture(scope)
      {token, display_token} = display_token_fixture(scope, [view])

      assert DisplayTokens.verify_token(String.duplicate("a", 43)) == :error
      assert DisplayTokens.verify_token("short") == :error
      assert DisplayTokens.verify_token(token <> "x") == :error
      assert DisplayTokens.verify_token(String.replace(token, ~r/^./, "!")) == :error
      assert DisplayTokens.verify_token(nil) == :error

      display_token
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1))
      |> Repo.update!()

      assert DisplayTokens.verify_token(token) == :error
      assert DisplayTokens.get_valid_token(display_token.id) == :error
    end

    test "marks the token as used, at most once a minute" do
      scope = scope()
      view = saved_view_fixture(scope)
      {token, display_token} = display_token_fixture(scope, [view])
      assert display_token.last_used_at == nil

      assert {:ok, %{last_used_at: %DateTime{} = used}} = DisplayTokens.verify_token(token)

      earlier = DateTime.add(used, -30)
      Repo.update_all(DisplayToken, set: [last_used_at: earlier])
      assert {:ok, %{last_used_at: ^earlier}} = DisplayTokens.get_valid_token(display_token.id)

      long_ago = DateTime.add(used, -120)
      Repo.update_all(DisplayToken, set: [last_used_at: long_ago])
      assert {:ok, %{last_used_at: touched}} = DisplayTokens.get_valid_token(display_token.id)
      assert DateTime.compare(touched, long_ago) == :gt
      assert Repo.get!(DisplayToken, display_token.id).last_used_at == touched
    end
  end

  describe "display_views/1" do
    test "only the views the creator sees now, in order" do
      creator = scope(["ops"])
      owner = scope(["ops"])
      own = saved_view_fixture(creator, name: "Own")
      shared = saved_view_fixture(owner, name: "Shared", visibility: :shared)
      group = saved_view_fixture(owner, name: "Ops", visibility: :groups, groups: ["ops"])

      {_token, display_token} = display_token_fixture(creator, [group, own, shared])
      assert display_names(display_token) == ["Ops", "Own", "Shared"]

      # The owner makes their shared view personal: the token stops showing
      # it, and shows it again once it's shared again.
      {:ok, shared} = SavedViews.update_view(owner, shared, %{visibility: :personal})
      assert display_names(display_token) == ["Ops", "Own"]
      {:ok, _shared} = SavedViews.update_view(owner, shared, %{visibility: :shared})
      assert display_names(display_token) == ["Ops", "Own", "Shared"]

      # The creator leaves the group (as of their next login).
      Accounts.upsert_oidc_user(%{
        oidc_issuer: creator.user.oidc_issuer,
        oidc_subject: creator.user.oidc_subject,
        email: creator.user.email,
        groups: []
      })

      assert display_names(display_token) == ["Own", "Shared"]

      # A deleted view is gone from the token.
      {:ok, _own} = SavedViews.delete_view(creator, own)
      assert display_names(display_token) == ["Shared"]
      assert DisplayTokens.get_token(creator, display_token.id).view_ids == [group.id, shared.id]
    end

    test "deleting the creator deletes their tokens and disconnects displays" do
      creator = scope()
      view = saved_view_fixture(creator, visibility: :shared)
      {token, display_token} = display_token_fixture(creator, [view])
      DisplayTokens.subscribe(display_token)

      {:ok, _user, _sessions} = Accounts.delete_user(creator.user)

      assert_receive {:display_token_revoked}
      assert DisplayTokens.verify_token(token) == :error
      refute Repo.get(DisplayToken, display_token.id)
    end

    defp display_names(display_token),
      do: display_token |> DisplayTokens.display_views() |> Enum.map(& &1.name)
  end

  describe "managing tokens" do
    test "users list, change and revoke only their own tokens" do
      scope = scope()
      other = scope()
      view = saved_view_fixture(scope, visibility: :shared)
      second = saved_view_fixture(scope)
      {token, display_token} = display_token_fixture(scope, [view], name: "TV")
      {_other_token, others} = display_token_fixture(other, [view])

      assert [%{id: id}] = DisplayTokens.list_tokens(scope)
      assert id == display_token.id
      assert DisplayTokens.get_token(scope, display_token.id).view_ids == [view.id]
      refute DisplayTokens.get_token(scope, others.id)
      refute DisplayTokens.get_token(scope, "nope")

      DisplayTokens.subscribe(display_token)

      assert {:ok, updated} =
               DisplayTokens.update_token(scope, display_token, %{
                 name: "Lobby",
                 view_ids: [second.id, view.id]
               })

      assert updated.name == "Lobby"
      assert updated.view_ids == [second.id, view.id]
      assert_receive {:display_token_changed}

      # Renaming alone keeps the views.
      assert {:ok, %{view_ids: [_, _]}} = DisplayTokens.update_token(scope, updated, %{name: "X"})

      assert DisplayTokens.update_token(scope, others, %{name: "Mine"}) == {:error, :forbidden}
      assert DisplayTokens.delete_token(scope, others) == {:error, :forbidden}

      assert {:ok, _} = DisplayTokens.delete_token(scope, updated)
      assert_receive {:display_token_revoked}
      assert DisplayTokens.verify_token(token) == :error
      assert DisplayTokens.list_tokens(scope) == []
    end

    test "a token keeps views its creator no longer sees, but can't gain any" do
      creator = scope()
      owner = scope()
      shared = saved_view_fixture(owner, visibility: :shared)
      hidden = saved_view_fixture(owner, visibility: :personal)
      own = saved_view_fixture(creator)
      {_token, display_token} = display_token_fixture(creator, [shared, own])
      {:ok, _} = SavedViews.update_view(owner, shared, %{visibility: :personal})

      # Kept (and not shown) while the creator doesn't see it.
      display_token = DisplayTokens.get_token(creator, display_token.id)
      assert {:ok, renamed} = DisplayTokens.update_token(creator, display_token, %{name: "TV"})
      assert renamed.view_ids == [shared.id, own.id]
      assert Enum.map(DisplayTokens.display_views(renamed), & &1.id) == [own.id]

      assert {:error, changeset} =
               DisplayTokens.update_token(creator, renamed, %{view_ids: [own.id, hidden.id]})

      assert "you can only choose views you can see" in errors_on(changeset).view_ids

      assert {:ok, %{view_ids: [own_id]}} =
               DisplayTokens.update_token(creator, renamed, %{view_ids: [own.id]})

      assert own_id == own.id
    end
  end
end
